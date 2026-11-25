#include "input/ControllerInput.h"
#include "SdlJoystickTestSession.h"

#include <QSignalSpy>
#include <QTest>

#include <array>
#include <numbers>

namespace {
constexpr int buttonsArgument = 2;
constexpr int leftTriggerArgument = 3;
constexpr int rightTriggerArgument = 4;
constexpr int leftStickXArgument = 5;
constexpr int rightStickXArgument = 7;
constexpr int rightStickYArgument = 8;
constexpr quint64 sampleStepNs = 10'000'000;

// A pad with everything the mapping layer reads: back paddles, extra buttons, two single-finger
// touchpads and a gyro.
class MappingPad final
{
public:
    explicit MappingPad(quint16 vendor = 0, quint16 product = 0)
    {
        static constexpr std::array<SDL_VirtualJoystickTouchpadDesc, 2> touchpads{{{1, {}}, {1, {}}}};
        static constexpr std::array<SDL_VirtualJoystickSensorDesc, 1> sensors{{{SDL_SENSOR_GYRO, 250.0f}}};
        SDL_VirtualJoystickDesc descriptor{};
        SDL_INIT_INTERFACE(&descriptor);
        descriptor.type = SDL_JOYSTICK_TYPE_GAMEPAD;
        descriptor.vendor_id = vendor;
        descriptor.product_id = product;
        descriptor.naxes = SDL_GAMEPAD_AXIS_COUNT;
        descriptor.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
        descriptor.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1;
        descriptor.button_mask = (1u << SDL_GAMEPAD_BUTTON_COUNT) - 1;
        descriptor.ntouchpads = touchpads.size();
        descriptor.touchpads = touchpads.data();
        descriptor.nsensors = sensors.size();
        descriptor.sensors = sensors.data();
        descriptor.name = "OpenNOW controller mapping test";
        id = SDL_AttachVirtualJoystick(&descriptor);
    }

    ~MappingPad() { if (id) SDL_DetachVirtualJoystick(id); }

    bool button(SDL_GamepadButton button, bool pressed)
    {
        return SDL_SetJoystickVirtualButton(SDL_GetJoystickFromID(id), button, pressed);
    }

    bool touch(int touchpad, bool down, float x, float y)
    {
        return SDL_SetJoystickVirtualTouchpad(SDL_GetJoystickFromID(id), touchpad, 0, down, x, y, down ? 1.0f : 0.0f);
    }

    // Sends one gyro reading and advances the sensor clock by one step.
    bool gyro(float pitch, float yaw)
    {
        const std::array<float, 3> data{pitch, yaw, 0.0f};
        sensorClockNs += sampleStepNs;
        return SDL_SendJoystickVirtualSensorData(SDL_GetJoystickFromID(id), SDL_SENSOR_GYRO, sensorClockNs,
                                                 data.data(), static_cast<int>(data.size()));
    }

    SDL_JoystickID id = 0;
    quint64 sensorClockNs = 0;
};

QVariantMap metadataFor(const ControllerInput &input, SDL_JoystickID id)
{
    for (const auto &entry : input.availableControllers()) {
        const auto map = entry.toMap();
        if (map.value(QStringLiteral("instanceId")).toULongLong() == id) return map;
    }
    return {};
}

void assign(ControllerInput &input, SDL_JoystickID id, const QVariantMap &profile)
{
    input.setControllerProfiles({{metadataFor(input, id).value(QStringLiteral("profileKey")).toString(), profile}});
}

int lastArgument(const QSignalSpy &spy, int argument)
{
    return spy.isEmpty() ? -1 : spy.last().at(argument).toInt();
}

QPoint totalMotion(const QSignalSpy &spy)
{
    QPoint total;
    for (const auto &motion : spy) total += QPoint(motion.at(0).toInt(), motion.at(1).toInt());
    return total;
}
}

class ControllerMappingTest final : public QObject
{
    Q_OBJECT

private:
    SdlJoystickTestSession m_joysticks;

private slots:
    void initTestCase() { QVERIFY2(m_joysticks.ready(), SDL_GetError()); }
    void cleanup() { QVERIFY2(m_joysticks.reset(), SDL_GetError()); }

    void parsesStoredProfilesAndDropsUnknownValues()
    {
        using namespace ControllerMapping;
        const auto profile = parse({
            {QStringLiteral("bindPaddle1"), QStringLiteral("pad:a")},
            {QStringLiteral("bindPaddle2"), QStringLiteral("pad:rt")},
            {QStringLiteral("bindPaddle3"), QStringLiteral("key:32")},
            {QStringLiteral("bindPaddle4"), QStringLiteral("mouse:right")},
            {QStringLiteral("bindMisc1"), QStringLiteral("key:999")},
            {QStringLiteral("bindTouchpad"), QStringLiteral("pad:nothing")},
            {QStringLiteral("bindMisc2"), 7},
            {QStringLiteral("gyroMode"), QStringLiteral("mouse")},
            {QStringLiteral("gyroActivation"), QStringLiteral("misc5")},
            {QStringLiteral("gyroSensitivity"), 9000},
            {QStringLiteral("leftPadMode"), QStringLiteral("leftStick")},
            {QStringLiteral("rightPadMode"), QStringLiteral("sideways")},
            {QStringLiteral("rightPadSensitivity"), QStringLiteral("fast")},
        });
        QCOMPARE(profile.bindings[0], (Target{Target::Kind::PadButton, 0x1000}));
        QCOMPARE(profile.bindings[1], (Target{Target::Kind::RightTrigger, 0}));
        QCOMPARE(profile.bindings[2], (Target{Target::Kind::Key, 32}));
        QCOMPARE(profile.bindings[3], (Target{Target::Kind::MouseButton, 3}));
        QCOMPARE(profile.bindings[4], Target{});
        QCOMPARE(profile.bindings[5], Target{});
        QCOMPARE(profile.bindings[6], Target{});
        QCOMPARE(profile.gyro, GyroMode::Mouse);
        QCOMPARE(profile.gyroActivation, (Activation{Activation::Kind::ExtraButton, extraBit(SDL_GAMEPAD_BUTTON_MISC5)}));
        QCOMPARE(profile.gyroSensitivity, maximumSensitivity);
        QCOMPARE(profile.touchpads[0], TouchpadMode::LeftStick);
        QCOMPARE(profile.touchpads[1], TouchpadMode::Off);
        QCOMPARE(profile.touchpadSensitivity[1], defaultSensitivity);
        QCOMPARE(parse({}), Profile{});
    }

    void reportsWhatAPadCanMap()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        const auto metadata = metadataFor(input, pad.id);
        const auto extras = metadata.value(QStringLiteral("extraButtons")).toStringList();
        QVERIFY(extras.contains(QStringLiteral("paddle1")));
        QVERIFY(extras.contains(QStringLiteral("misc6")));
        QCOMPARE(metadata.value(QStringLiteral("hasGyro")).toBool(), true);
        QCOMPARE(metadata.value(QStringLiteral("touchpads")).toInt(), 2);
        QCOMPARE(metadata.value(QStringLiteral("steamLayout")).toBool(), false);
    }

    void paddlesReachTheGamepadPacket()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        assign(input, pad.id, {{QStringLiteral("bindPaddle1"), QStringLiteral("pad:a")},
                               {QStringLiteral("bindPaddle2"), QStringLiteral("pad:rt")}});
        input.setShellCaptureEnabled(false);
        QSignalSpy snapshots(&input, &ControllerInput::gamepadSnapshot);

        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, true));
        QTRY_COMPARE(lastArgument(snapshots, buttonsArgument), 0x1000);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_LEFT_PADDLE1, true));
        QTRY_COMPARE(lastArgument(snapshots, rightTriggerArgument), 255);
        QCOMPARE(lastArgument(snapshots, leftTriggerArgument), 0);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, false));
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_LEFT_PADDLE1, false));
        QTRY_COMPARE(lastArgument(snapshots, rightTriggerArgument), 0);
        QCOMPARE(lastArgument(snapshots, buttonsArgument), 0);

        // An unbound paddle stays silent.
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2, true));
        QTest::qWait(40);
        QCOMPARE(lastArgument(snapshots, buttonsArgument), 0);
    }

    void changingABindingWhileHeldMovesTheOutput()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        assign(input, pad.id, {{QStringLiteral("bindPaddle1"), QStringLiteral("pad:a")}});
        input.setShellCaptureEnabled(false);
        QSignalSpy snapshots(&input, &ControllerInput::gamepadSnapshot);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, true));
        QTRY_COMPARE(lastArgument(snapshots, buttonsArgument), 0x1000);
        assign(input, pad.id, {{QStringLiteral("bindPaddle1"), QStringLiteral("pad:b")}});
        QCOMPARE(lastArgument(snapshots, buttonsArgument), 0x2000);
        assign(input, pad.id, {});
        QCOMPARE(lastArgument(snapshots, buttonsArgument), 0);
    }

    void keysAndMouseButtonsReleaseWhenTheShellTakesThePad()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        assign(input, pad.id, {{QStringLiteral("bindPaddle3"), QStringLiteral("key:32")},
                               {QStringLiteral("bindPaddle4"), QStringLiteral("mouse:right")}});
        QSignalSpy keys(&input, &ControllerInput::mappedKey);
        QSignalSpy buttons(&input, &ControllerInput::mappedMouseButton);

        // The shell owns the pad: nothing reaches the stream.
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2, true));
        QTest::qWait(60);
        QVERIFY(keys.isEmpty());

        // Handing the pad to the stream sends what is already held.
        input.setShellCaptureEnabled(false);
        QCOMPARE(keys.size(), 1);
        QCOMPARE(keys.last().at(0).toInt(), 32);
        QCOMPARE(keys.last().at(1).toBool(), true);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_LEFT_PADDLE2, true));
        QTRY_COMPARE(buttons.size(), 1);
        QCOMPARE(buttons.last().at(0).toInt(), 3);
        QCOMPARE(buttons.last().at(1).toBool(), true);

        input.setShellCaptureEnabled(true);
        QCOMPARE(keys.size(), 2);
        QCOMPARE(keys.last().at(1).toBool(), false);
        QCOMPARE(buttons.size(), 2);
        QCOMPARE(buttons.last().at(1).toBool(), false);

        input.setShellCaptureEnabled(false);
        QCOMPARE(keys.size(), 3);
        input.setInputSuspended(true);
        QCOMPARE(keys.size(), 4);
        QCOMPARE(keys.last().at(1).toBool(), false);
        QCOMPARE(buttons.last().at(1).toBool(), false);
    }

    void disconnectingReleasesHeldKeys()
    {
        ControllerInput input;
        QSignalSpy keys(&input, &ControllerInput::mappedKey);
        {
            MappingPad pad;
            QVERIFY2(pad.id, SDL_GetError());
            QTRY_COMPARE(input.controllerCount(), 1);
            assign(input, pad.id, {{QStringLiteral("bindMisc1"), QStringLiteral("key:69")}});
            input.setShellCaptureEnabled(false);
            QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_MISC1, true));
            QTRY_COMPARE(keys.size(), 1);
        }
        QTRY_COMPARE(input.controllerCount(), 0);
        QCOMPARE(keys.size(), 2);
        QCOMPARE(keys.last().at(0).toInt(), 69);
        QCOMPARE(keys.last().at(1).toBool(), false);
    }

    void gyroMovesTheMouseOnlyWhileItsActivatorIsHeld()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        assign(input, pad.id, {{QStringLiteral("gyroMode"), QStringLiteral("mouse")},
                               {QStringLiteral("gyroActivation"), QStringLiteral("misc5")}});
        input.setShellCaptureEnabled(false);
        QSignalSpy motion(&input, &ControllerInput::mappedMouseMotion);

        // One radian per second to the left and tilting back, without the grip held.
        for (int sample = 0; sample < 6; ++sample) QVERIFY2(pad.gyro(1.0f, 1.0f), SDL_GetError());
        QTest::qWait(60);
        QVERIFY(motion.isEmpty());

        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_MISC5, true));
        QTest::qWait(40);
        // The first reading only starts the clock; ten more are 100 ms of rotation, 5.73 degrees.
        for (int sample = 0; sample < 11; ++sample) QVERIFY2(pad.gyro(1.0f, 1.0f), SDL_GetError());
        const auto expected = -qRound(0.1 * (180.0 / std::numbers::pi) * ControllerMapping::gyroMouseCountsPerDegree);
        QTRY_VERIFY(qAbs(totalMotion(motion).x() - expected) <= 1);
        QVERIFY(qAbs(totalMotion(motion).y() - expected) <= 1);

        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_MISC5, false));
        QTest::qWait(40);
        const auto settled = motion.size();
        for (int sample = 0; sample < 6; ++sample) QVERIFY2(pad.gyro(1.0f, 1.0f), SDL_GetError());
        QTest::qWait(60);
        QCOMPARE(motion.size(), settled);
    }

    void gyroAsRightStickDeflectsAndRecentres()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        assign(input, pad.id, {{QStringLiteral("gyroMode"), QStringLiteral("rightStick")}});
        input.setShellCaptureEnabled(false);
        QSignalSpy snapshots(&input, &ControllerInput::gamepadSnapshot);

        // Turning right at 90 degrees per second is half of the full-scale rate.
        const auto quarterTurn = static_cast<float>(-std::numbers::pi / 2.0);
        QVERIFY2(pad.gyro(0.0f, quarterTurn), SDL_GetError());
        QTRY_VERIFY(qAbs(lastArgument(snapshots, rightStickXArgument) - 16384) <= 2);
        QCOMPARE(lastArgument(snapshots, rightStickYArgument), 0);

        // No further readings: the stick must not stay deflected.
        QTRY_COMPARE(lastArgument(snapshots, rightStickXArgument), 0);
    }

    void trackpadsDriveTheMouseOrAStick()
    {
        ControllerInput input;
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        assign(input, pad.id, {{QStringLiteral("leftPadMode"), QStringLiteral("leftStick")},
                               {QStringLiteral("rightPadMode"), QStringLiteral("mouse")},
                               {QStringLiteral("rightPadSensitivity"), 50}});
        input.setShellCaptureEnabled(false);
        QSignalSpy motion(&input, &ControllerInput::mappedMouseMotion);
        QSignalSpy snapshots(&input, &ControllerInput::gamepadSnapshot);

        // Landing a finger does not move the pointer; sliding it does.
        QVERIFY(pad.touch(1, true, 0.5f, 0.5f));
        QTest::qWait(40);
        QVERIFY(motion.isEmpty());
        QVERIFY(pad.touch(1, true, 0.7f, 0.4f));
        // Half sensitivity: a fifth of the pad is 120 counts, a tenth is 60. Whole counts are sent
        // and the fraction is carried, so the total may trail by one.
        QTRY_VERIFY(qAbs(totalMotion(motion).x() - 120) <= 1);
        QVERIFY(qAbs(totalMotion(motion).y() + 60) <= 1);
        QVERIFY(pad.touch(1, false, 0.7f, 0.4f));

        QVERIFY(pad.touch(0, true, 1.0f, 0.5f));
        QTRY_COMPARE(lastArgument(snapshots, leftStickXArgument), 32767);
        QVERIFY(pad.touch(0, false, 1.0f, 0.5f));
        QTRY_COMPARE(lastArgument(snapshots, leftStickXArgument), 0);
    }

    void importedLayoutDecidesEverythingThePadSends()
    {
        // A layout in Steam's own format: A types Q, the upper right back button is the gamepad's
        // B, the right trackpad is the mouse and the left trigger keeps its travel.
        const auto layout = SteamInput::Config::fromVdf(QStringLiteral(R"vdf(
"controller_mappings"
{
    "title" "Test"
    "group" { "id" "0" "mode" "four_buttons" "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press Q" } } } } } }
    "group" { "id" "1" "mode" "switches" "inputs" { "button_back_right_upper" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button B" } } } } } }
    "group" { "id" "2" "mode" "absolute_mouse" "inputs" { } }
    "group" { "id" "3" "mode" "trigger" "inputs" { } "settings" { "output_trigger" "1" } }
    "preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "button_diamond active" "1" "switch active" "2" "right_trackpad active" "3" "left_trigger active" } }
}
)vdf"));
        QVERIFY(layout.has_value());
        ControllerInput input;
        input.setLayoutProvider([&](const QString &id) {
            return id == QStringLiteral("imported") ? layout : std::nullopt;
        });
        MappingPad pad;
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        // The binding made in OpenNOW stays in the profile but is not used while a layout is.
        assign(input, pad.id, {{QStringLiteral("layout"), QStringLiteral("imported")},
                               {QStringLiteral("bindPaddle1"), QStringLiteral("pad:a")}});
        QCOMPARE(metadataFor(input, pad.id).value(QStringLiteral("layout")).toString(), QStringLiteral("imported"));
        input.setShellCaptureEnabled(false);
        QSignalSpy keys(&input, &ControllerInput::mappedKey);
        QSignalSpy motion(&input, &ControllerInput::mappedMouseMotion);
        QSignalSpy snapshots(&input, &ControllerInput::gamepadSnapshot);

        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_SOUTH, true));
        QTRY_COMPARE(keys.size(), 1);
        QCOMPARE(keys.last().at(0).toInt(), 0x51);
        QCOMPARE(keys.last().at(1).toBool(), true);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, true));
        QTRY_COMPARE(lastArgument(snapshots, buttonsArgument), 0x2000);
        // SDL spreads a virtual trigger axis's whole range over the pull, so this is three quarters.
        QVERIFY(SDL_SetJoystickVirtualAxis(SDL_GetJoystickFromID(pad.id), SDL_GAMEPAD_AXIS_LEFT_TRIGGER, 16384));
        QTRY_VERIFY(qAbs(lastArgument(snapshots, leftTriggerArgument) - 191) <= 1);

        QVERIFY(pad.touch(1, true, 0.5f, 0.5f));
        QTest::qWait(40);
        QVERIFY(motion.isEmpty());
        QVERIFY(pad.touch(1, true, 0.6f, 0.5f));
        // A tenth of the pad's width is a fifth of its -1...1 span: 120 counts.
        QTRY_VERIFY(qAbs(totalMotion(motion).x() - 120) <= 1);

        // The shell takes the pad: the key comes up and the game gets a neutral packet.
        input.setShellCaptureEnabled(true);
        QCOMPARE(keys.size(), 2);
        QCOMPARE(keys.last().at(1).toBool(), false);
        // What is still held when play resumes stays ignored until it is let go.
        input.setShellCaptureEnabled(false);
        QTest::qWait(60);
        QCOMPARE(keys.size(), 2);
        QCOMPARE(lastArgument(snapshots, buttonsArgument), 0);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_SOUTH, false));
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, false));
        QTest::qWait(40);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_SOUTH, true));
        QTRY_COMPARE(keys.size(), 3);
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_SOUTH, false));
        QTRY_COMPARE(keys.size(), 4);

        // Without the layout the pad is its ordinary self again, bindings made here included.
        assign(input, pad.id, {{QStringLiteral("bindPaddle1"), QStringLiteral("pad:a")}});
        QCOMPARE(metadataFor(input, pad.id).value(QStringLiteral("layout")).toString(), QString());
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_SOUTH, true));
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1, true));
        QTRY_COMPARE(lastArgument(snapshots, buttonsArgument), 0x1000);
        QCOMPARE(keys.size(), 4);
    }

    void valveTouchSensorsDoNotHoldShellInput_data()
    {
        QTest::addColumn<int>("vendor");
        QTest::addColumn<bool>("draining");
        QTest::newRow("steam-controller") << 0x28de << false;
        QTest::newRow("other-pad") << 0x1234 << true;
    }

    void valveTouchSensorsDoNotHoldShellInput()
    {
        QFETCH(int, vendor);
        QFETCH(bool, draining);
        ControllerInput input;
        MappingPad pad(static_cast<quint16>(vendor), 0x0f0f);
        QVERIFY2(pad.id, SDL_GetError());
        QTRY_COMPARE(input.controllerCount(), 1);
        QSignalSpy skips(&input, &ControllerInput::shellInputSkipRequested);
        input.setShellInputBlocked(true);
        // A resting hand closes the grip sensor.
        QVERIFY(pad.button(SDL_GAMEPAD_BUTTON_MISC5, true));
        QTest::qWait(80);
        QCOMPARE(input.shellInputDraining(), draining);
        QCOMPARE(!skips.isEmpty(), draining);
    }
};

QTEST_MAIN(ControllerMappingTest)
#include "tst_controllermapping.moc"
