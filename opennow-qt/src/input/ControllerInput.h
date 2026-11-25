#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QHash>
#include <QPointF>
#include <QPointer>
#include <QStringList>
#include <QTimer>
#include <QVariantList>

#include <array>
#include <functional>
#include <memory>
#include <optional>

#include <SDL3/SDL.h>

#include "input/ControllerMapping.h"
#include "input/SteamInputEngine.h"
#include "input/SdlDeviceClaim.h"
#include "input/GenericHidWire.h"

class GenericHidInput;
class GenericHidBackend;

class ControllerInput final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int controllerCount READ controllerCount NOTIFY controllerCountChanged)
    Q_PROPERTY(QVariantList controllers READ controllers NOTIFY controllersChanged)
    Q_PROPERTY(QVariantList availableControllers READ availableControllers NOTIFY availableControllersChanged)
    Q_PROPERTY(QVariantList flightDevices READ flightDevices NOTIFY flightDevicesChanged)
    Q_PROPERTY(QVariantList supportedFlightDevices READ supportedFlightDevices CONSTANT)
    Q_PROPERTY(bool forwardFlightControls READ forwardFlightControls WRITE setForwardFlightControls NOTIFY forwardFlightControlsChanged)
    Q_PROPERTY(quint32 inputControllerId READ inputControllerId WRITE setInputControllerId NOTIFY inputControllerIdChanged)
    Q_PROPERTY(bool shellCaptureEnabled READ shellCaptureEnabled WRITE setShellCaptureEnabled NOTIFY shellCaptureEnabledChanged)
    Q_PROPERTY(bool inputSuspended READ inputSuspended WRITE setInputSuspended NOTIFY inputSuspendedChanged)
    Q_PROPERTY(bool shellInputBlocked READ shellInputBlocked WRITE setShellInputBlocked NOTIFY shellInputBlockedChanged)
    Q_PROPERTY(bool shellInputDraining READ shellInputDraining NOTIFY shellInputDrainingChanged)
    Q_PROPERTY(int leftStickDeadzone READ leftStickDeadzone WRITE setLeftStickDeadzone NOTIFY leftStickDeadzoneChanged)
    Q_PROPERTY(int rightStickDeadzone READ rightStickDeadzone WRITE setRightStickDeadzone NOTIFY rightStickDeadzoneChanged)
    Q_PROPERTY(int vibrationIntensity READ vibrationIntensity WRITE setVibrationIntensity NOTIFY vibrationIntensityChanged)
    Q_PROPERTY(QVariantMap controllerProfiles READ controllerProfiles WRITE setControllerProfiles NOTIFY controllerProfilesChanged)
    Q_PROPERTY(bool leftStickNavigationEnabled READ leftStickNavigationEnabled WRITE setLeftStickNavigationEnabled NOTIFY leftStickNavigationEnabledChanged)
    Q_PROPERTY(QVariantList steamMenus READ steamMenus NOTIFY steamMenusChanged)

public:
    static constexpr quint32 syntheticControllerScanCode = 0x4f504e57;
    static constexpr int maxSources = maxSdlSources;
    static constexpr float sonyContactCenter = 0.5f;

    struct SonyContact {
        bool active = false;
        bool hasPosition = false;
        float x = 0.0f;
        float y = 0.0f;
    };

    struct SonySnapshot {
        quint8 slot = 0;
        quint64 incarnation = 0;
        quint16 buttons = 0;
        quint8 leftTrigger = 0;
        quint8 rightTrigger = 0;
        qint16 leftStickX = 0;
        qint16 leftStickY = 0;
        qint16 rightStickX = 0;
        qint16 rightStickY = 0;
        bool touchpadClick = false;
        std::array<SonyContact, 2> contacts{};
        quint64 observedAtUs = 0;
    };

    explicit ControllerInput(QObject *parent = nullptr, std::shared_ptr<GenericHidBackend> hidBackend = {});
    ~ControllerInput() override;

    [[nodiscard]] int controllerCount() const;
    [[nodiscard]] QVariantList controllers() const;
    [[nodiscard]] QVariantList availableControllers() const;
    [[nodiscard]] QVariantList flightDevices() const { return m_flightDevices; }
    [[nodiscard]] bool forwardFlightControls() const { return m_forwardFlightControls; }
    void setForwardFlightControls(bool enabled);
    [[nodiscard]] QVariantList supportedFlightDevices() const;
    [[nodiscard]] quint32 inputControllerId() const;
    void setInputControllerId(quint32 id);
    [[nodiscard]] bool shellCaptureEnabled() const;
    void setShellCaptureEnabled(bool enabled);
    [[nodiscard]] bool inputSuspended() const;
    void setInputSuspended(bool suspended);
    [[nodiscard]] bool shellInputBlocked() const { return m_shellInputBlocked; }
    [[nodiscard]] bool shellInputDraining() const { return m_shellInputDraining; }
    void setShellInputBlocked(bool blocked);
    [[nodiscard]] int leftStickDeadzone() const;
    [[nodiscard]] int rightStickDeadzone() const;
    [[nodiscard]] int vibrationIntensity() const;
    void setLeftStickDeadzone(int percent);
    void setRightStickDeadzone(int percent);
    void setVibrationIntensity(int percent);
    [[nodiscard]] QVariantMap controllerProfiles() const { return m_controllerProfiles; }
    void setControllerProfiles(const QVariantMap &profiles);
    [[nodiscard]] bool leftStickNavigationEnabled() const { return m_leftStickNavigationEnabled; }
    void setLeftStickNavigationEnabled(bool enabled);
    // The radial and touch menus imported layouts have open, for drawing over the game.
    [[nodiscard]] QVariantList steamMenus() const { return m_steamMenus; }
    // Where pads' imported Steam layouts come from. A pad's profile names one by ID.
    using LayoutProvider = std::function<std::optional<SteamInput::Config>(const QString &id)>;
    void setLayoutProvider(LayoutProvider provider);
    Q_INVOKABLE QVariantMap stickSample(quint32 instanceId) const;
    Q_INVOKABLE bool testRumble(quint32 instanceId);
    [[nodiscard]] static QString profileKey(quint16 vendor, quint16 product, const char *serial, SDL_GUID guid);
    void playRumble(quint8 controllerId, quint16 lowFrequency, quint16 highFrequency, quint32 durationMs,
                    quint64 sourceIncarnation = 0);
    void stopRumble();
    [[nodiscard]] QList<SdlDeviceClaim> deviceClaims() const;
    [[nodiscard]] QList<GenericHidDeviceClaim> genericHidClaims() const;

public slots:
    void setGenericHidAdmission(quint8 slot, quint64 incarnation, GenericHidAdmission admission);
    void resetGenericHidAdmissions();
    void handleGenericHidOutput(const GenericHidReport &report);
    // Looks every pad's layout up again, after layouts were imported or removed.
    void reloadLayouts();
    void stopGenericHidOutput();

signals:
    void controllerCountChanged(int count);
    void controllersChanged();
    void availableControllersChanged();
    void flightDevicesChanged();
    void forwardFlightControlsChanged();
    void inputControllerIdChanged();
    void shellCaptureEnabledChanged();
    void inputSuspendedChanged();
    void shellInputBlockedChanged();
    void shellInputDrainingChanged();
    void shellInputSkipRequested();
    void leftStickDeadzoneChanged();
    void rightStickDeadzoneChanged();
    void vibrationIntensityChanged();
    void controllerProfilesChanged();
    void leftStickNavigationEnabledChanged();
    void controllerActivity();
    void controllerActivityDetailed(const QString &device, const QString &control, int value);
    void gamepadSnapshot(quint8 controllerId, quint16 bitmap, quint16 buttons,
                         quint8 leftTrigger, quint8 rightTrigger,
                         qint16 leftStickX, qint16 leftStickY,
                         qint16 rightStickX, qint16 rightStickY);
    void deviceClaimsChanged();
    void genericDeviceClaimsChanged();
    void genericHidReport(const GenericHidReport &report);
    void inputDiagnostic(const QString &message);
    void sonySnapshot(const ControllerInput::SonySnapshot &snapshot);
    void localActionRequested(quint32 action);
    void mappedMouseMotion(qint16 deltaX, qint16 deltaY);
    void mappedMouseButton(quint8 button, bool pressed);
    void mappedKey(quint16 virtualKey, bool pressed);
    // A point of the stream, as fractions of its width and height from the top left.
    void mappedMouseAbsolute(double x, double y);
    void mappedMouseWheel(qint16 deltaX, qint16 deltaY);
    void steamMenusChanged();

private slots:
    void poll();

private:
    struct RepeatingDirection {
        bool active = false;
        qint64 pressedAt = 0;
        qint64 repeatedAt = 0;
        int key = 0;
    };

    struct ShellKeyPress {
        QPointer<QObject> target;
        qint64 pressedAt = 0;
        qint64 repeatedAt = 0;
    };

    struct GamepadSlot {
        SDL_Gamepad *gamepad = nullptr;
        SDL_JoystickID instanceId = 0;
        quint16 buttons = 0;
        qint16 rawLeftX = 0;
        qint16 rawLeftY = 0;
        qint16 rawRightX = 0;
        qint16 rawRightY = 0;
        quint8 leftTrigger = 0;
        quint8 rightTrigger = 0;
        bool rumbleFailureReported = false;
        quint64 incarnation = 0;
        quint16 vendor = 0;
        quint16 product = 0;
        QString profileKey;
        bool hasSerial = false;
        int leftDeadzone = 5;
        int rightDeadzone = 5;
        int vibration = 100;
        bool touchpadClick = false;
        bool guideLatched = false;
        quint16 withheldButtons = 0;
        quint16 tappedButtons = 0;
        qint64 chordDeadline = 0;
        quint64 chordStartedNs = 0;
        qint64 tapReleaseAt = 0;
        struct MappedTouchpad {
            bool down = false;
            QPointF position;
            QPointF stick;
        };
        ControllerMapping::Profile mapping;
        QStringList extraButtonNames;
        bool hasGyro = false;
        int touchpadCount = 0;
        quint32 extraHeld = 0;
        quint16 mappedButtons = 0;
        bool mappedLeftTrigger = false;
        bool mappedRightTrigger = false;
        std::array<bool, 4> mappedMouseButtons{};
        QList<quint16> mappedKeys;
        std::array<MappedTouchpad, 2> touchpads{};
        quint64 gyroSampleNs = 0;
        QPointF gyroStick;
        qint64 gyroStickAt = 0;
        QPointF pointerPending;
        QPointF pointerRemainder;
        bool mappingDirty = false;
        // An imported Steam layout, which then decides everything this pad sends.
        QString layoutId;
        std::optional<SteamInput::Engine> layout;
        SteamInput::Engine::Pad layoutPad;
        float layoutGyroPitch = 0.0f;
        float layoutGyroYaw = 0.0f;
        double layoutGyroInterval = 0.0;
        quint64 layoutGyroSampleNs = 0;
        QPointF layoutPointerRemainder;
        bool layoutDirty = false;
        [[nodiscard]] quint16 forwardedButtons() const
        {
            return static_cast<quint16>(((buttons | tappedButtons) & ~withheldButtons) | mappedButtons);
        }
        [[nodiscard]] quint8 forwardedLeftTrigger() const { return mappedLeftTrigger ? 255 : leftTrigger; }
        [[nodiscard]] quint8 forwardedRightTrigger() const { return mappedRightTrigger ? 255 : rightTrigger; }
        std::array<SonyContact, 2> contacts{};
        QHash<int, ShellKeyPress> shellKeys;
        std::array<RepeatingDirection, 4> directions{{
            {false, 0, 0, Qt::Key_Left}, {false, 0, 0, Qt::Key_Right},
            {false, 0, 0, Qt::Key_Up}, {false, 0, 0, Qt::Key_Down}}};
    };

    void openController(SDL_JoystickID id);
    void closeController(SDL_JoystickID id);
    void handleButton(const SDL_GamepadButtonEvent &event, bool pressed);
    void handleAxis(const SDL_GamepadAxisEvent &event);
    void handleTouchpad(const SDL_GamepadTouchpadEvent &event);
    void handleMappedTouchpad(int slotIndex, const SDL_GamepadTouchpadEvent &event);
    void handleSensor(const SDL_GamepadSensorEvent &event);
    [[nodiscard]] bool streamOwnsSlot(const GamepadSlot &slot) const;
    [[nodiscard]] bool gyroActive(const GamepadSlot &slot) const;
    bool applyMapping(int slotIndex);
    void releaseMappedOutputs(int slotIndex);
    bool flushMappedMotion(int slotIndex, qint64 now);
    void updateSensorState(const GamepadSlot &slot) const;
    [[nodiscard]] QPair<qint16, qint16> outputStick(const GamepadSlot &slot, bool right) const;
    [[nodiscard]] SteamInput::Report layoutReport(const GamepadSlot &slot) const;
    bool runLayout(int slotIndex, bool fresh);
    bool sendLayoutOutput(int slotIndex, const SteamInput::Engine::Output &output);
    void refreshSteamMenus();
    void sampleSonyContacts(int slotIndex);
    void publishSonySnapshot(int slotIndex, bool neutral = false);
    void publishConnectedSony(bool neutral = false);
    void publishConnectedInputs(bool neutral = false);
    void publishSlotSnapshot(int slotIndex, bool neutral = false);
    void releaseSonyContacts(int slotIndex);
    void cancelChordReplays();
    void resumeStreamInput();
    [[nodiscard]] int effectiveSlot(int slotIndex) const;
    bool updateDirection(RepeatingDirection &direction, bool active);
    void reportActivity(int slot, const QString &control, int value);
    void dispatchRepeats(qint64 now);
    void resetDirections();
    void handleShellButton(int slot, int key, bool pressed);
    void releaseShellButtons(int slot);
    [[nodiscard]] bool acceptsController(SDL_JoystickID id) const;
    void postKey(int key, bool pressed, bool autoRepeat = false, QObject *target = nullptr);
    static int keyForButton(Uint8 button);
    [[nodiscard]] quint16 gamepadBitmap() const;
    void publishGamepad(int slot, bool neutral = false);
    void publishConnectedGamepads(bool neutral = false);
    void updateSlotSnapshot(int slot);
    void updatePollInterval();
    void updateShellInputDrain();
    [[nodiscard]] bool isSonySlot(int slotIndex) const;
    void refreshControllerMetadata();
    void refreshFlightDevices();
    void applySlotTuning();
    void tuneSlot(GamepadSlot &slot) const;
    static quint16 buttonMask(Uint8 button);
    static QPair<qint16, qint16> radialDeadzone(qint16 x, qint16 y, int percent);
    static quint8 triggerValue(qint16 value);

    QTimer m_pollTimer;
    std::unique_ptr<GenericHidInput> m_genericHid;
    QVariantList m_controllerMetadata;
    QVariantList m_availableControllerMetadata;
    QVariantList m_flightDevices;
    QSet<SDL_JoystickID> m_noHidPathDevices;
    QHash<SDL_JoystickID, quint64> m_flightFirstSeenScan;
    quint64 m_hidScanGeneration = 0;
    bool m_hidPathCheckPending = false;
    QHash<quint64, GenericHidAdmission> m_genericHidAdmissions;
    bool m_forwardFlightControls = true;
    SDL_JoystickID m_inputControllerId = 0;
    QElapsedTimer m_clock;
    QHash<SDL_JoystickID, int> m_gamepadSlots;
    std::array<GamepadSlot, 4> m_slots;
    bool m_sdlReady = false;
    bool m_shellCaptureEnabled = true;
    bool m_inputSuspended = false;
    bool m_shellInputBlocked = false;
    bool m_shellInputDraining = false;
    int m_leftStickDeadzone = 5;
    int m_rightStickDeadzone = 5;
    int m_vibrationIntensity = 100;
    QVariantMap m_controllerProfiles;
    LayoutProvider m_layoutProvider;
    QVariantList m_steamMenus;
    bool m_leftStickNavigationEnabled = true;
    qint64 m_lastControllerMetadataAt = 0;
    qint64 m_lastGamepadSnapshotAt = 0;
    quint64 m_streamInputStartedNs = 0;
    quint64 m_nextIncarnation = 1;
};

Q_DECLARE_METATYPE(ControllerInput::SonySnapshot)
