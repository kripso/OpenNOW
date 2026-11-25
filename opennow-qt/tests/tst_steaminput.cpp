#include "input/SteamInputConfig.h"
#include "input/SteamInputEngine.h"

#include <QPointF>
#include <QString>
#include <QStringList>
#include <QTest>

#include <algorithm>
#include <cmath>
#include <functional>
#include <initializer_list>
#include <map>
#include <numbers>
#include <utility>

namespace Vdf = SteamInput::Vdf;

namespace {

using SteamInput::Button;
using SteamInput::Buttons;
using SteamInput::Config;
using SteamInput::Engine;
using SteamInput::PadButton;
using SteamInput::Report;
using SteamInput::Shortcut;
using SteamInput::Vector;

using Source = Config::Source;
using Mode = Config::Mode;
using Binding = Config::Binding;
using Activator = Config::Activator;
using InputRef = Config::InputRef;
using Group = Config::Group;
using ActionSet = Config::ActionSet;
using Pad = Engine::Pad;
using Output = Engine::Output;
using Menu = Engine::Menu;

// A failed check is reported with the expression that failed, and the test carries on.
#define CHECK(...) QVERIFY2((__VA_ARGS__), #__VA_ARGS__)

// A small layout in Steam's own format, shaped like the community layouts it is modelled on: two
// action sets, one layer, a mode shift onto a radial menu, and every press type.
const char *const layoutText = R"VDF(
"controller_mappings"
{
    "version"		"3"
    "title"		"#Title"
    "controller_type"		"controller_neptune"
    "localization" { "english" { "Title" "Test Layout" } }
    "actions"
    {
        "Default" { "title" "On Foot" "legacy_set" "1" }
        "Preset_1000002" { "title" "Flying" "legacy_set" "1" }
    }
    "action_layers"
    {
        "Preset_1000001" { "title" "Bumper Layer" "set_layer" "1" "parent_set_name" "Default" }
    }
    "group"
    {
        "id" "0" "mode" "four_buttons"
        "inputs"
        {
            "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press SPACE, Jump" } } } }
            "button_b" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 3" } } } }
            "button_x"
            {
                "activators"
                {
                    "Full_Press" { "bindings" { "binding" "key_press 1" } }
                    "Long_Press" { "bindings" { "binding" "key_press 2" } "settings" { "long_press_time" "300" } }
                }
            }
            "button_y"
            {
                "activators"
                {
                    "Double_Press" { "bindings" { "binding" "key_press F" } "settings" { "doubetap_max_duration" "250" } }
                    "Start_Press" { "bindings" { "binding" "key_press G" } }
                    "release" { "bindings" { "binding" "key_press H" } }
                }
            }
        }
    }
    "group"
    {
        "id" "1" "mode" "switches"
        "inputs"
        {
            "left_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action hold_layer 2 0 0" } } } }
            "right_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_SHIFT" } "settings" { "toggle" "1" } } } }
            "button_escape" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action CHANGE_PRESET 3 0 0" } } } }
            "button_menu" { "activators" { "Full_Press" { "bindings" { "binding" "game_action Menus open_map, , " } } } }
            "button_back_right_upper" { "activators" { "Full_Press" { "bindings" { "binding" "mode_shift left_trackpad 6" } } } }
            "button_back_left" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action SHOW_KEYBOARD" } } } }
        }
    }
    "group"
    {
        "id" "2" "mode" "four_buttons"
        "inputs"
        {
            "button_b" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 9" } } } }
        }
        "settings" { "layer" "1" }
    }
    "group" { "id" "3" "mode" "trigger" "inputs" { "click" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_button RIGHT" } } } } } "settings" { "output_trigger" "2" } }
    "group" { "id" "4" "mode" "scrollwheel" "inputs"
        {
            "scroll_clockwise" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_wheel SCROLL_DOWN" } } } }
            "scroll_counterclockwise" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_wheel SCROLL_UP" } } } }
        }
        "settings" { "scroll_angle" "45" }
    }
    "group"
    {
        "id" "5" "mode" "radial_menu" "name" "Mounts"
        "inputs"
        {
            "touch_menu_button_0" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_CONTROL, Raptor, @mount.png, " "binding" "key_press 1, Raptor, @mount.png, " } } } }
            "touch_menu_button_1" { "activators" { "Full_Press" { "bindings" { "binding" "key_press K, Skimmer" } } } }
            "touch_menu_button_2" { "activators" { "Full_Press" { "bindings" { "binding" "key_press L, Griffon" } } } }
            "touch_menu_button_3" { "activators" { "Full_Press" { "bindings" { "binding" "key_press M" } } } }
        }
    }
    "group" { "id" "6" "mode" "reference" "settings" { "referenced_mode" "5" } }
    "group" { "id" "7" "mode" "four_buttons" "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } } } } }
    "group" { "id" "8" "mode" "gyro_to_mouse" "inputs" { } "settings" { "gyro_button" "12" } }
    "group" { "id" "9" "mode" "mouse_region" "inputs" { } }
    "group" { "id" "10" "mode" "switches" "inputs" { "button_escape" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action CHANGE_PRESET 1 0 0" } } } } } }
    "preset"
    {
        "id" "0" "name" "Default"
        "group_source_bindings"
        {
            "0" "button_diamond active"
            "1" "switch active"
            "3" "right_trigger active"
            "4" "left_trackpad active"
            "6" "left_trackpad inactive modeshift"
            "8" "gyro active"
            "9" "right_trackpad active"
            "7" "button_diamond inactive"
        }
    }
    "preset" { "id" "1" "name" "Preset_1000001" "group_source_bindings" { "2" "button_diamond active" } }
    "preset" { "id" "2" "name" "Preset_1000002" "group_source_bindings" { "7" "button_diamond active" "10" "switch active" } }
}
)VDF";

// Valve's text format at its most varied: a comment, repeated keys, escaped quotes and nesting.
const char *const valveText = R"VDF(
// a comment
"Root" { bare value "quoted \"text\"" "with space"
    "binding" "one" "binding" "two" nested { "deep" "1" } }
)VDF";

const char *const nothingText = R"VDF("controller_mappings" { "title" "Nothing" })VDF";

QString layoutFixture()
{
    return QString::fromUtf8(layoutText);
}

// The layout the fixture imports to. An import that fails leaves an empty layout, so the checks
// that follow it fail rather than crash.
Config parseFixture(const QString &text)
{
    return Config::fromVdf(text).value_or(Config{});
}

Report makeReport(std::initializer_list<Button> buttons = {}, const std::function<void(Report &)> &change = {})
{
    Report report;
    for (const Button button : buttons) report.buttons |= button;
    if (change) change(report);
    return report;
}

QList<quint16> pressedKeys(const Output &output)
{
    QList<quint16> codes;
    for (const auto &event : output.keys) {
        if (event.pressed) codes.append(event.virtualKey);
    }
    return codes;
}

QList<quint16> releasedKeys(const Output &output)
{
    QList<quint16> codes;
    for (const auto &event : output.keys) {
        if (!event.pressed) codes.append(event.virtualKey);
    }
    return codes;
}

QString render(const QList<quint16> &codes)
{
    QStringList parts;
    for (const quint16 code : codes) parts.append(QStringLiteral("0x%1").arg(static_cast<uint>(code), 0, 16));
    return parts.join(QStringLiteral(", "));
}

// Compares virtual-key codes as the host would see them. Unordered comparisons are for sets.
void expectKeys(QList<quint16> actual, std::initializer_list<quint16> expected, bool unordered = false)
{
    QList<quint16> wanted(expected);
    if (unordered) {
        std::sort(actual.begin(), actual.end());
        std::sort(wanted.begin(), wanted.end());
    }
    QCOMPARE(render(actual), render(wanted));
}

bool nearly(double actual, double expected, double accuracy)
{
    return std::abs(actual - expected) <= accuracy;
}

// A layout with one set, built directly: each source given a group in the wanted mode.
Config singleSetConfig(const std::map<Source, Group> &sources)
{
    Config config;
    ActionSet set;
    set.id = 0;
    for (const auto &[source, group] : sources) {
        config.groups[group.id] = group;
        set.groups[source] = group.id;
    }
    config.sets[0] = set;
    return config;
}

Group sourceGroup(int id, Mode mode, std::initializer_list<std::pair<QString, double>> settings = {})
{
    Group group;
    group.id = id;
    group.mode = mode;
    for (const auto &[key, value] : settings) group.settings[key] = value;
    return group;
}

// The text of a layout that turns the gyro into mouse movement, with the given group settings.
QString gyroLayout(const QString &settings)
{
    return QStringLiteral("\"controller_mappings\" { \"group\" { \"id\" \"0\" \"mode\" \"gyro_to_mouse\" \"settings\" { %1 } }"
                          " \"preset\" { \"id\" \"0\" \"name\" \"Default\" \"group_source_bindings\" { \"0\" \"gyro active\" } } }")
        .arg(settings);
}

} // namespace

class SteamInputTest : public QObject
{
    Q_OBJECT

private slots:
    void testValveKeyValueTextIsParsedWithRepeatedKeysCommentsAndEscapes()
    {
        const auto value = Vdf::parse(QString::fromUtf8(valveText));
        CHECK(value.has_value());
        const Vdf::Value *root = value->child(QStringLiteral("root"));
        CHECK(root);
        QCOMPARE(Vdf::stringOf(root->child(QStringLiteral("bare"))).value_or(QString()), QStringLiteral("value"));
        QCOMPARE(Vdf::stringOf(root->child(QStringLiteral("quoted \"text\""))).value_or(QString()),
                 QStringLiteral("with space"));
        QStringList bindings;
        for (const Vdf::Value *binding : root->all(QStringLiteral("binding"))) {
            if (const auto text = Vdf::stringOf(binding)) bindings.append(*text);
        }
        QCOMPARE(bindings, QStringList({QStringLiteral("one"), QStringLiteral("two")}));
        QCOMPARE(Vdf::stringOf(root->child(QStringLiteral("nested"))
                                   ? root->child(QStringLiteral("nested"))->child(QStringLiteral("deep"))
                                   : nullptr)
                     .value_or(QString()),
                 QStringLiteral("1"));
        const QString unclosed = QStringLiteral("\"open\" ") + QLatin1Char('{') + QStringLiteral(" \"never\" \"closed\"");
        CHECK(!Vdf::parse(unclosed));
        QString deep;
        for (int index = 0; index < 64; ++index) {
            deep += QStringLiteral("\"a\" ");
            deep += QLatin1Char('{');
        }
        CHECK(!Vdf::parse(deep));
        CHECK(!Config::fromVdf(QStringLiteral("not a layout")));
        CHECK(!Config::fromVdf(QString::fromUtf8(nothingText)));
    }

    void testLayoutFileBecomesSetsLayersGroupsAndNotes()
    {
        const auto parsed = Config::fromVdf(layoutFixture());
        CHECK(parsed.has_value());
        const Config config = parsed.value_or(Config{});
        QCOMPARE(config.title, QStringLiteral("Test Layout"));
        QCOMPARE(config.controllerType, QStringLiteral("controller_neptune"));
        QCOMPARE(config.defaultSet, 0);
        QCOMPARE(config.sets.at(0).title, QStringLiteral("On Foot"));
        CHECK(config.sets.at(1).isLayer);
        QCOMPARE(config.sets.at(2).title, QStringLiteral("Flying"));
        // Inactive and mode-shift groups are not what a source uses by default.
        CHECK(config.sets.at(0).groups.at(Source::ButtonDiamond) == 0);
        CHECK(config.sets.at(0).groups.at(Source::LeftTrackpad) == 4);
        // A reference stands for the group it points at.
        CHECK(config.groups.at(6).mode == Mode::RadialMenu);
        QCOMPARE(config.groups.at(6).name, QStringLiteral("Mounts"));
        CHECK(config.groups.at(5).inputs.at(QStringLiteral("touch_menu_button_0")).first().bindings
              == (QList<Binding>{Binding::key(0xa2), Binding::key(0x31)}));
        QCOMPARE(config.groups.at(5).inputs.at(QStringLiteral("touch_menu_button_0")).first().label,
                 QStringLiteral("Raptor"));
        const auto &buttonX = config.groups.at(0).inputs.at(QStringLiteral("button_x"));
        CHECK(buttonX.size() == 2);
        CHECK(buttonX[0].kind == Activator::Kind::FullPress);
        CHECK(buttonX[1].kind == Activator::Kind::LongPress);
        CHECK(config.groups.at(0).inputs.at(QStringLiteral("button_x")).last().longPressTime == 0.3);
        CHECK(config.groups.at(1).inputs.at(QStringLiteral("left_bumper")).first().bindings
              == QList<Binding>{Binding::holdLayer(1)});
        CHECK(config.groups.at(1).inputs.at(QStringLiteral("button_escape")).first().bindings
              == QList<Binding>{Binding::changeSet(2)});
        CHECK(config.groups.at(1).inputs.at(QStringLiteral("button_back_right_upper")).first().bindings
              == QList<Binding>{Binding::modeShift(Source::LeftTrackpad, 6)});
        CHECK(config.groups.at(8).gyroActivators == QList<InputRef>{InputRef{Source::LeftTrigger, QStringLiteral("edge")}});
        CHECK(config.groups.at(8).gyroActivation == Config::GyroActivation::WhileHeld);
        CHECK(config.groups.at(9).mode == Mode::MouseRegion);
        CHECK(config.usesGyro());
        // The Steam button is reserved by Steam, so imported layouts get OpenNOW's default for it.
        const int system = config.sets.at(0).groups.at(Source::System);
        CHECK(config.groups.at(system).inputs.at(QStringLiteral("steam")).first().bindings
              == QList<Binding>{Binding::shortcut(Shortcut::Controls)});

        // A control bound to one of the game's own actions is sent as the matching gamepad button.
        CHECK(config.groups.at(1).inputs.at(QStringLiteral("button_menu")).first().bindings
              == QList<Binding>{Binding::pad(PadButton::Back)});
        CHECK(config.notes.size() == 2);
        CHECK(std::any_of(config.notes.cbegin(), config.notes.cend(), [](const QString &note) {
            return note.contains(QStringLiteral("(1) are bound to the game's own Steam Input actions"));
        }));
        CHECK(std::any_of(config.notes.cbegin(), config.notes.cend(), [](const QString &note) {
            return note.contains(QStringLiteral("show_keyboard"));
        }));
    }

    // MARK: Running a layout

    void testLayerChangesOnlyWhatItListsAndAHeldButtonKeepsItsMeaning()
    {
        Engine engine(parseFixture(layoutFixture()));
        expectKeys(pressedKeys(engine.apply(makeReport({Button::B}), 0)), {0x33});
        // The layer comes on while B is still down: B keeps sending 3 until it is let go.
        Output output = engine.apply(makeReport({Button::B, Button::LeftBumper}), 0.01);
        CHECK(output.keys.isEmpty());
        output = engine.apply(makeReport({Button::LeftBumper}), 0.02);
        expectKeys(releasedKeys(output), {0x33});
        // In the layer B is 9, and A, which the layer does not mention, is still Space.
        output = engine.apply(makeReport({Button::LeftBumper, Button::B, Button::A}), 0.03);
        expectKeys(pressedKeys(output), {0x39, 0x20}, true);
        output = engine.apply(makeReport({}), 0.04);
        expectKeys(pressedKeys(engine.apply(makeReport({Button::B}), 0.05)), {0x33});
    }

    void testLongDoubleStartAndReleasePressesFollowTheirTiming()
    {
        Engine engine(parseFixture(layoutFixture()));
        // X sends 1 at once and adds 2 once it has been held for 300 ms, with no new report needed.
        expectKeys(pressedKeys(engine.apply(makeReport({Button::X}), 0)), {0x31});
        CHECK(engine.advance(0.2).keys.isEmpty());
        expectKeys(pressedKeys(engine.advance(0.31)), {0x32});
        expectKeys(releasedKeys(engine.apply(makeReport({}), 0.4)), {0x31, 0x32}, true);

        // Y taps G on the way down and H on the way up; each tap ends by itself.
        expectKeys(pressedKeys(engine.apply(makeReport({Button::Y}), 1)), {0x47});
        expectKeys(releasedKeys(engine.advance(1.05)), {0x47});
        expectKeys(pressedKeys(engine.apply(makeReport({}), 1.06)), {0x48});
        expectKeys(releasedKeys(engine.advance(1.12)), {0x48});
        // A second press within 250 ms is a double press and holds F for as long as it is down.
        const Output doubled = engine.apply(makeReport({Button::Y}), 1.2);
        expectKeys(pressedKeys(doubled), {0x46, 0x47}, true);
        expectKeys(releasedKeys(engine.advance(1.3)), {0x47});
        CHECK(releasedKeys(engine.apply(makeReport({}), 1.4)).contains(0x46));
        engine.advance(1.5);
        // A slow second press is just another press.
        expectKeys(pressedKeys(engine.apply(makeReport({Button::Y}), 3)), {0x47});
    }

    void testToggleSetChangeTriggerAndGameActions()
    {
        Engine engine(parseFixture(layoutFixture()));
        // The right bumper toggles Shift: on with one press, off with the next.
        expectKeys(pressedKeys(engine.apply(makeReport({Button::RightBumper}), 0)), {0xa0});
        CHECK(engine.apply(makeReport({}), 0.1).keys.isEmpty());
        expectKeys(releasedKeys(engine.apply(makeReport({Button::RightBumper}), 0.2)), {0xa0});
        engine.apply(makeReport({}), 0.3);

        // The trigger keeps its analog travel and clicks the right mouse button at the end of it.
        Output output = engine.apply(makeReport({}, [](Report &r) { r.rightTrigger = 0.5f; }), 0.4);
        CHECK(output.pad.rightTrigger == 128);
        CHECK(output.mouseButtons.isEmpty());
        output = engine.apply(makeReport({Button::RightTriggerClick}, [](Report &r) { r.rightTrigger = 1; }), 0.5);
        CHECK(output.mouseButtons == QList<Engine::MouseButtonEvent>{{3, true}});
        engine.apply(makeReport({}), 0.6);

        // A binding to the game's own actions reaches the host as the gamepad's View button.
        CHECK(engine.apply(makeReport({Button::View}), 0.7).pad.buttons == 0x0020);
        engine.apply(makeReport({}), 0.8);

        // Menu switches to the Flying set, where A is the gamepad's A, and back again. A layout with
        // a single action set has no set name to show.
        Config single;
        ActionSet onlySet;
        onlySet.id = 0;
        single.sets[0] = onlySet;
        CHECK(!Engine(single).actionSetTitle());
        QCOMPARE(engine.actionSetTitle().value_or(QString()), QStringLiteral("On Foot"));
        engine.apply(makeReport({Button::Menu}), 0.9);
        QCOMPARE(engine.actionSetTitle().value_or(QString()), QStringLiteral("Flying"));
        engine.apply(makeReport({}), 1);
        output = engine.apply(makeReport({Button::A}), 1.1);
        CHECK(output.pad.buttons == 0x1000);
        CHECK(output.keys.isEmpty());
        engine.apply(makeReport({}), 1.2);
        engine.apply(makeReport({Button::Menu}), 1.3);
        QCOMPARE(engine.actionSetTitle().value_or(QString()), QStringLiteral("On Foot"));
    }

    void testCirclingThePadTurnsTheWheelAStepPerSoManyDegrees()
    {
        Engine engine(parseFixture(layoutFixture()));
        const auto at = [](double degrees) {
            return makeReport({Button::LeftPadTouch}, [degrees](Report &r) {
                r.leftPad = Vector{static_cast<float>(0.8 * std::sin(degrees * std::numbers::pi / 180)),
                                   static_cast<float>(0.8 * std::cos(degrees * std::numbers::pi / 180))};
            });
        };
        int wheel = 0;
        int index = 0;
        for (double degrees = 0; degrees <= 100; degrees += 10, ++index) {
            wheel += engine.apply(at(degrees), index * 0.01).wheel;
        }
        // 100 degrees clockwise at 45 degrees a step is two steps down.
        CHECK(wheel == -240);
        // Turning back first uses up the 10 degrees left over, so 60 degrees is one step up.
        wheel = 0;
        index = 0;
        for (double degrees = 100; degrees >= 40; degrees -= 10, ++index) {
            wheel += engine.apply(at(degrees), 1 + index * 0.01).wheel;
        }
        CHECK(wheel == 120);
    }

    void testModeShiftOpensAMenuThatIsShownAndPickedOnRelease()
    {
        Engine engine(parseFixture(layoutFixture()));
        engine.apply(makeReport({Button::R4}), 0);
        CHECK(engine.menus().isEmpty());
        // With the shift held, a thumb on the pad opens the menu; pointing right is the second of four.
        engine.apply(makeReport({Button::R4, Button::LeftPadTouch}, [](Report &r) { r.leftPad = Vector{0, 0}; }), 0.01);
        const Menu opened{Source::LeftTrackpad, true, QStringLiteral("Mounts"),
                          QStringList({QStringLiteral("Raptor"), QStringLiteral("Skimmer"), QStringLiteral("Griffon"),
                                       QStringLiteral("M")}),
                          std::nullopt};
        CHECK(engine.menus() == QList<Menu>{opened});
        engine.apply(makeReport({Button::R4, Button::LeftPadTouch}, [](Report &r) { r.leftPad = Vector{0.9f, 0}; }), 0.02);
        CHECK(engine.menus().value(0).selected == 1);
        engine.apply(makeReport({Button::R4, Button::LeftPadTouch}, [](Report &r) { r.leftPad = Vector{0, 0.9f}; }), 0.03);
        CHECK(engine.menus().value(0).selected == 0);
        // A click picks it: the item's keys go down together, modifier first, and come back up.
        const Output picked = engine.apply(
            makeReport({Button::R4, Button::LeftPadTouch, Button::LeftPadClick},
                       [](Report &r) { r.leftPad = Vector{0, 0.9f}; }),
            0.04);
        CHECK(picked.keys == (QList<Engine::KeyEvent>{
                                 Engine::KeyEvent{0xa2, true, 0x02},
                                 Engine::KeyEvent{0x31, true, 0x02},
                             }));
        expectKeys(releasedKeys(engine.advance(0.1)), {0x31, 0xa2});
        // Letting the shift go closes the menu and gives the pad back to the wheel.
        engine.apply(makeReport({Button::LeftPadTouch}, [](Report &r) { r.leftPad = Vector{0, 0.9f}; }), 0.2);
        engine.apply(makeReport({Button::LeftPadTouch}, [](Report &r) { r.leftPad = Vector{0, 0.9f}; }), 0.21);
        CHECK(engine.menus().isEmpty());
    }

    void testMenuGeometryMatchesWhatIsDrawn()
    {
        CHECK(!Engine::radialItem(Vector{0.1f, 0.1f}, 6));
        CHECK(Engine::radialItem(Vector{0, 1}, 6) == 0);
        CHECK(Engine::radialItem(Vector{1, 0}, 4) == 1);
        CHECK(Engine::radialItem(Vector{0, -1}, 4) == 2);
        CHECK(Engine::radialItem(Vector{-1, 0}, 4) == 3);
        // Seven items lie in three columns: the top left is the first, the bottom left the last.
        CHECK(Engine::gridColumns(7) == 3);
        CHECK(Engine::gridItem(Vector{-0.9f, 0.9f}, 7) == 0);
        CHECK(Engine::gridItem(Vector{0.9f, 0.9f}, 7) == 2);
        CHECK(Engine::gridItem(Vector{-0.9f, -0.9f}, 7) == 6);
        CHECK(!Engine::gridItem(Vector{0.9f, -0.9f}, 7));
    }

    void testImportedGyroFollowsItsEnableButton()
    {
        Engine engine(parseFixture(layoutFixture()));
        const auto turning = [](Report &r) {
            r.gyroYaw = 1;
            r.gyroInterval = 0.01;
        };
        CHECK(engine.apply(makeReport({}, turning), 0).mouse == QPointF(0, 0));
        const Output aiming = engine.apply(makeReport({}, [](Report &r) {
            r.gyroYaw = 1;
            r.gyroInterval = 0.01;
            r.leftTrigger = 0.6f;
        }), 0.01);
        CHECK(nearly(aiming.mouse.x(), -(180 / std::numbers::pi) * 0.01 * 20, 0.001));
    }

    // MARK: Modes that place the pointer, scroll and flick

    void testMouseRegionPlacesThePointerWhereTheThumbIs()
    {
        Engine engine(parseFixture(layoutFixture()));
        // The right trackpad covers the whole screen: up and to the right of centre on the pad is up
        // and to the right of centre on the screen.
        Output output = engine.apply(makeReport({Button::RightPadTouch}, [](Report &r) { r.rightPad = Vector{0.5f, 0.5f}; }), 0);
        CHECK(output.absolute.has_value());
        CHECK(nearly(output.absolute.value_or(QPointF()).x(), 0.75, 0.001));
        CHECK(nearly(output.absolute.value_or(QPointF()).y(), 0.25, 0.001));
        CHECK(output.mouse == QPointF(0, 0));
        // A thumb that has not moved sends nothing more.
        output = engine.apply(makeReport({Button::RightPadTouch}, [](Report &r) { r.rightPad = Vector{0.5f, 0.5f}; }), 0.01);
        CHECK(!output.absolute.has_value());

        // A region can be a smaller part of the screen, placed off centre.
        engine = Engine(singleSetConfig({{Source::RightTrackpad,
                                          sourceGroup(0, Mode::MouseRegion,
                                                      {{QStringLiteral("scale"), 50},
                                                       {QStringLiteral("position_x"), 25},
                                                       {QStringLiteral("position_y"), 80}})}}));
        output = engine.apply(makeReport({Button::RightPadTouch}, [](Report &r) { r.rightPad = Vector{1, -1}; }), 0);
        CHECK(output.absolute.has_value());
        CHECK(nearly(output.absolute.value_or(QPointF()).x(), 0.5, 0.001));
        CHECK(nearly(output.absolute.value_or(QPointF()).y(), 1, 0.001));
    }

    void testTwoWayScrollAndCalibrationScaleWhatTheLayoutAsksFor()
    {
        Engine engine(singleSetConfig({
            {Source::LeftTrackpad, sourceGroup(0, Mode::Scroll2D)},
            {Source::RightTrackpad, sourceGroup(1, Mode::AbsoluteMouse)},
        }));
        const auto swipe = [](Engine &target) {
            target.apply(makeReport({Button::LeftPadTouch, Button::RightPadTouch}), 0);
            return target.apply(makeReport({Button::LeftPadTouch, Button::RightPadTouch}, [](Report &r) {
                r.leftPad = Vector{0.2f, -0.1f};
                r.rightPad = Vector{0.1f, 0};
            }), 0.01);
        };
        Output output = swipe(engine);
        CHECK(output.wheelX == 240);
        CHECK(output.wheel == -120);
        CHECK(nearly(output.mouse.x(), 60, 0.001));

        engine = Engine(engine.config());
        engine.tuning.scroll = 50;
        engine.tuning.trackpadMouse = 200;
        output = swipe(engine);
        CHECK(output.wheelX == 120);
        CHECK(output.wheel == -60);
        CHECK(nearly(output.mouse.x(), 120, 0.001));
    }

    void testFlickStickTurnsToFaceWhereItIsPushedAndFollowsASweep()
    {
        Engine engine(singleSetConfig({{Source::RightJoystick, sourceGroup(0, Mode::FlickStick)}}));
        engine.tuning.flickTurn = 4'000;
        engine.apply(makeReport({}), 0);
        // Pushed straight right: a quarter turn, 1000 counts, spread over a tenth of a second.
        double travel = engine.apply(makeReport({}, [](Report &r) { r.rightStick = Vector{1, 0}; }), 0.01).mouse.x();
        for (int tick = 2; tick <= 15; ++tick) travel += engine.advance(tick * 0.01).mouse.x();
        CHECK(nearly(travel, 1'000, 0.5));
        // Swept from right round to straight back: another quarter turn, at once.
        const double sweep = engine.apply(makeReport({}, [](Report &r) { r.rightStick = Vector{0, -1}; }), 0.2).mouse.x();
        CHECK(nearly(sweep, 1'000, 0.5));
        // Let go and pushed left: a quarter turn the other way. The stick itself sends nothing.
        engine.apply(makeReport({}), 0.3);
        Output back = engine.apply(makeReport({}, [](Report &r) { r.rightStick = Vector{-1, 0}; }), 0.31);
        CHECK(back.pad == Pad());
        double total = back.mouse.x();
        for (int tick = 32; tick <= 45; ++tick) {
            back = engine.advance(tick * 0.01);
            total += back.mouse.x();
        }
        CHECK(nearly(total, -1'000, 0.5));
    }

    void testGyroButtonSetCanToggleOrPauseTheGyro()
    {
        const auto turning = [](Report &r) {
            r.gyroYaw = 1;
            r.gyroInterval = 0.01;
        };
        const auto moves = [&turning](Engine &target, std::initializer_list<Button> buttons, double time) {
            return target.apply(makeReport(buttons, turning), time).mouse != QPointF(0, 0);
        };

        // Bit 16 is the right back button; setting 2 makes it a toggle.
        Config config = parseFixture(gyroLayout(QStringLiteral("\"gyro_ratchet_button_mask\" \"65536\" \"gyro_button_invert\" \"2\"")));
        CHECK(config.groups.at(0).gyroActivators == QList<InputRef>{InputRef{Source::Switches, QStringLiteral("button_back_right")}});
        Engine engine(config);
        CHECK(!moves(engine, {}, 0));
        CHECK(moves(engine, {Button::R5}, 0.01));
        CHECK(moves(engine, {}, 0.02));
        CHECK(!moves(engine, {Button::R5}, 0.03));

        // Setting 1 turns it round: the gyro works until the button is held.
        config = parseFixture(gyroLayout(QStringLiteral("\"gyro_ratchet_button_mask\" \"64\" \"gyro_button_invert\" \"1\"")));
        CHECK(config.groups.at(0).gyroActivators == QList<InputRef>{InputRef{Source::ButtonDiamond, QStringLiteral("button_x")}});
        engine = Engine(config);
        CHECK(moves(engine, {}, 0));
        CHECK(!moves(engine, {Button::X}, 0.01));

        // A button the pad report has no place for is said so, and the rest still applies.
        config = parseFixture(gyroLayout(QStringLiteral("\"gyro_ratchet_button_mask\" \"140737488355332\"")));
        CHECK(config.groups.at(0).gyroActivators == QList<InputRef>{InputRef{Source::Switches, QStringLiteral("right_bumper")}});
        CHECK(std::any_of(config.notes.cbegin(), config.notes.cend(), [](const QString &note) {
            return note.contains(QStringLiteral("button 47"));
        }));
    }

    void testMenuItemsWithoutALabelShowWhatTheySend()
    {
        const Config config = parseFixture(layoutFixture());
        QCOMPARE(config.groups.at(5).inputs.at(QStringLiteral("touch_menu_button_3")).first().displayLabel(),
                 QStringLiteral("M"));
        Activator unlabelled;
        unlabelled.bindings = {Binding::key(0xa3), Binding::key(0x31)};
        QCOMPARE(unlabelled.displayLabel(), QStringLiteral("Ctrl+1"));
    }

    // The library's overrides, applied to an imported layout: only the chosen set changes, and the
    // layout as published stays as it was.
    void testLibraryOverridesChangeOnlyTheChosenSet()
    {
        const Config published = parseFixture(layoutFixture());
        Config changed = published;
        changed.applyOverrides({
            {Config::overrideKey(0, Source::ButtonDiamond, QStringLiteral("button_a")), QStringLiteral("key:81")},
            {Config::overrideKey(0, Source::Switches, QStringLiteral("button_back_left_upper")), QStringLiteral("pad:x")},
        });
        Engine engine(changed);
        expectKeys(pressedKeys(engine.apply(makeReport({Button::A}), 0)), {0x51});
        CHECK(engine.apply(makeReport({Button::A, Button::L4}), 0.01).pad.buttons == 0x4000);
        CHECK(published.groups.at(0).inputs.at(QStringLiteral("button_a")).first().bindings
              == QList<Binding>{Binding::key(0x20)});
        // A second config parsed from the fixture is unchanged by the overrides.
        CHECK(parseFixture(layoutFixture()) == published);
    }
};

QTEST_GUILESS_MAIN(SteamInputTest)
#include "tst_steaminput.moc"
