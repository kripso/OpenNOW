#pragma once

#include <QFlags>
#include <QList>
#include <QString>
#include <QStringList>
#include <QHash>

#include <cstddef>
#include <map>
#include <optional>
#include <set>
#include <vector>

// Steam Input layouts: Valve's text format, the layout model that imports it, and the pad report
// the engine consumes. Layouts made in OpenNOW and layouts imported from Steam both become a
// SteamInput::Config, so one engine runs them all.
namespace SteamInput {

namespace Vdf {

struct Entry;

// Valve's text key-value format, which Steam Input layouts are saved in: quoted or bare strings,
// nested objects in braces, and keys that may repeat.
class Value {
public:
    static Value makeString(QString text);
    static Value makeObject(std::vector<Entry> entries);

    std::optional<QString> string() const;
    const std::vector<Entry> &entries() const;
    // The first child with this key; keys compare without regard to case, as Steam's do.
    const Value *child(const QString &key) const;
    std::vector<const Value *> all(const QString &key) const;

private:
    bool object_ = false;
    QString text_;
    std::vector<Entry> entries_;
};

struct Entry {
    QString key;
    Value value;
};

// Returns nullopt when the text is not well-formed. Nesting is limited so a hostile file cannot
// exhaust the stack.
std::optional<Value> parse(const QString &text);

// The string held by a value, when there is one.
std::optional<QString> stringOf(const Value *value);

} // namespace Vdf

// An optional sign and then decimal digits, nothing else.
std::optional<long long> parseInteger(const QString &text);

// The second-generation Steam Controller's buttons, as the pad report flags them.
enum class Button : quint32 {
    A = 0x0000'0001,
    B = 0x0000'0002,
    X = 0x0000'0004,
    Y = 0x0000'0008,
    QuickAccess = 0x0000'0010,
    RightStickClick = 0x0000'0020,
    View = 0x0000'0040,
    R4 = 0x0000'0080,
    R5 = 0x0000'0100,
    RightBumper = 0x0000'0200,
    DpadDown = 0x0000'0400,
    DpadRight = 0x0000'0800,
    DpadLeft = 0x0000'1000,
    DpadUp = 0x0000'2000,
    Menu = 0x0000'4000,
    LeftStickClick = 0x0000'8000,
    Steam = 0x0001'0000,
    L4 = 0x0002'0000,
    L5 = 0x0004'0000,
    LeftBumper = 0x0008'0000,
    RightStickTouch = 0x0010'0000,
    RightPadTouch = 0x0020'0000,
    RightPadClick = 0x0040'0000,
    // The switch at the end of the trigger's travel.
    RightTriggerClick = 0x0080'0000,
    LeftStickTouch = 0x0100'0000,
    LeftPadTouch = 0x0200'0000,
    LeftPadClick = 0x0400'0000,
    LeftTriggerClick = 0x0800'0000,
    RightGrip = 0x1000'0000,
    LeftGrip = 0x2000'0000,
};
Q_DECLARE_FLAGS(Buttons, Button)
Q_DECLARE_OPERATORS_FOR_FLAGS(Buttons)

// A point on a stick or trackpad: x grows to the right and y grows upward, both about -1...1.
struct Vector {
    float x = 0;
    float y = 0;

    float length() const;
    friend bool operator==(const Vector &, const Vector &) = default;
};

// One state report from the pad.
struct Report {
    Buttons buttons;
    // 0 released, 1 fully pulled.
    float leftTrigger = 0;
    float rightTrigger = 0;
    Vector leftStick;
    Vector rightStick;
    // Only meaningful while the matching touch flag is set.
    Vector leftPad;
    Vector rightPad;
    // Rotation rate in radians per second. Positive pitch tilts the top of the pad toward the
    // player and positive yaw turns it to the left.
    float gyroPitch = 0;
    float gyroYaw = 0;
    // Seconds of rotation this reading covers; zero when it repeats the previous sample.
    double gyroInterval = 0;

    friend bool operator==(const Report &, const Report &) = default;
};

// The controls on a gamepad packet. The triggers are analog and have no bit.
enum class PadButton { A, B, X, Y, Lb, Rb, Lt, Rt, Ls, Rs, Back, Start, Guide, Up, Down, Left, Right };

// The bit in the gamepad packet; the triggers are separate analog fields.
quint16 padButtonMask(PadButton button);
// The layout token for a pad button, such as "lb".
QString padButtonToken(PadButton button);
std::optional<PadButton> padButtonFromToken(const QString &token);

// The stream's own shortcuts, which a binding can open from the pad.
enum class Shortcut { Controls, Stats };
QString shortcutToken(Shortcut shortcut);
QString shortcutLabel(Shortcut shortcut);
std::optional<Shortcut> shortcutFromToken(const QString &token);

// The player's own scaling of pointer, gyro and wheel output, applied to whichever layout is in
// use. Layouts do not carry the game's pointer speed, so matching the feel of another device is
// done here. Percentages.
struct Tuning {
    int trackpadMouse = 100;
    int stickMouse = 100;
    int gyro = 100;
    int scroll = 100;
    // How far the pointer must travel to turn the view once round, for flick stick.
    int flickTurn = 4'000;
};

// A layout in Steam Input's own terms: action sets and layers, each assigning a group to a source
// on the pad; a group's mode says how the source behaves and its inputs carry activators with
// bindings.
class Config {
public:
    enum class Source {
        ButtonDiamond,
        Dpad,
        Joystick,
        RightJoystick,
        LeftTrackpad,
        RightTrackpad,
        LeftTrigger,
        RightTrigger,
        Gyro,
        Switches,
        // The Steam button and the grip sensors, which Steam's own layouts cannot bind.
        System,
    };

    enum class Mode {
        FourButtons,
        Switches,
        Dpad,
        SingleButton,
        Trigger,
        JoystickMove,
        JoystickCamera,
        JoystickMouse,
        AbsoluteMouse,
        MouseJoystick,
        ScrollWheel,
        // A swipe up or down the pad turns the wheel; Steam's own wheel mode is circular.
        LinearScroll,
        GyroToMouse,
        GyroToJoystick,
        FlickStick,
        // The surface stands for an area of the screen: where the thumb is, the pointer goes.
        MouseRegion,
        // A swipe scrolls both ways.
        Scroll2D,
        RadialMenu,
        TouchMenu,
        Disabled,
    };

    enum class GyroActivation { WhileHeld, WhileReleased, Toggle };

    struct InputRef {
        Source source = Source::ButtonDiamond;
        QString input;

        friend bool operator==(const InputRef &, const InputRef &) = default;
        friend bool operator<(const InputRef &left, const InputRef &right);
    };

    struct Binding {
        enum class Kind {
            // A Windows virtual-key code.
            Key,
            // 1 left, 2 middle, 3 right, 4 back, 5 forward.
            MouseButton,
            // One notch: +1 up, -1 down.
            Wheel,
            Pad,
            ChangeSet,
            HoldLayer,
            AddLayer,
            RemoveLayer,
            // While held, the source uses another group.
            ModeShift,
            Shortcut,
        };

        Kind kind = Kind::Key;
        // The key code, button, direction, set or group, or the PadButton or Shortcut as an int.
        int value = 0;
        // Only meaningful for ModeShift.
        Source source = Source::ButtonDiamond;

        static Binding key(int code);
        static Binding mouseButton(int button);
        static Binding wheel(int direction);
        static Binding pad(PadButton button);
        static Binding changeSet(int set);
        static Binding holdLayer(int layer);
        static Binding addLayer(int layer);
        static Binding removeLayer(int layer);
        static Binding modeShift(Source source, int group);
        static Binding shortcut(Shortcut action);

        PadButton padButton() const;
        Shortcut shortcutAction() const;

        // A few words for what this sends, for menus and summaries.
        QString shortTitle() const;

        friend bool operator==(const Binding &, const Binding &) = default;
    };

    struct Activator {
        enum class Kind { FullPress, SoftPress, LongPress, DoublePress, StartPress, Release };

        Kind kind = Kind::FullPress;
        QList<Binding> bindings;
        // The author's name for what this does, shown in on-screen menus.
        QString label;
        bool toggle = false;
        bool holdRepeats = false;
        double repeatInterval = 0.1;
        double longPressTime = 0.15;
        double doubleTapTime = 0.25;
        double delayStart = 0;
        double delayEnd = 0;
        // Bound to one of the game's own Steam Input actions, which cannot be sent from here.
        bool nativeAction = false;

        // The author's label, or failing that what it sends, such as "Ctrl+1".
        QString displayLabel() const;

        friend bool operator==(const Activator &, const Activator &) = default;
    };

    struct Group {
        int id = 0;
        Mode mode = Mode::Disabled;
        QString name;
        std::map<QString, QList<Activator>> inputs;
        std::map<QString, double> settings;
        // For gyro groups: the inputs that switch the gyro; none means it is always on.
        QList<InputRef> gyroActivators;
        GyroActivation gyroActivation = GyroActivation::WhileHeld;

        friend bool operator==(const Group &, const Group &) = default;
    };

    struct ActionSet {
        int id = 0;
        QString title;
        bool isLayer = false;
        std::map<Source, int> groups;

        friend bool operator==(const ActionSet &, const ActionSet &) = default;
    };

    // Reads a Steam Input layout file (`controller_mappings`). Anything it uses that has no
    // equivalent outside Steam is left out and described in `notes`. Returns nullopt when the text
    // is not a layout.
    static std::optional<Config> fromVdf(const QString &text);

    // The key an override is stored under.
    static QString overrideKey(int set, Source source, const QString &input);

    // Replaces what single inputs do, as the player chose after importing. Each override gives
    // the input one ordinary press; a group shared with other sets is copied first so only the
    // chosen set changes.
    void applyOverrides(const QHash<QString, QString> &overrides);

    // Whether any gyro group is in use, so the pad is only asked for readings when needed.
    bool usesGyro() const;

    QString title;
    QString controllerType;
    std::map<int, ActionSet> sets;
    int defaultSet = 0;
    std::map<int, Group> groups;
    // What the layout asks for that OpenNOW cannot do, in words for the player.
    QStringList notes;

    friend bool operator==(const Config &, const Config &) = default;
};

// The name of a source, as layouts spell it.
QString sourceToken(Config::Source source);
std::optional<Config::Source> sourceFromToken(const QString &token);
bool isSurface(Config::Source source);
bool isTrackpad(Config::Source source);

// The name of a mode, as layouts spell it.
std::optional<Config::Mode> modeFromToken(const QString &token);

// What one control sends. Stored as a short token so layouts stay readable and tolerate values a
// later version adds.
class Action {
public:
    enum class Kind { None, Pad, Key, Mouse, Wheel, Shortcut };

    static Action none();
    static Action pad(PadButton button);
    static Action key(int code);
    // 1 left, 2 middle, 3 right.
    static Action mouse(int button);
    // One notch per press: +1 up, -1 down.
    static Action wheel(int direction);
    static Action shortcut(Shortcut action);

    // Parses a token such as "pad:a", "key:81" or "app:controls".
    static std::optional<Action> fromToken(const QString &token);
    QString token() const;
    // This action as a Steam Input layout expresses it.
    QList<Config::Binding> bindings() const;

    Kind kind() const { return kind_; }

    friend bool operator==(const Action &, const Action &) = default;

private:
    Action(Kind kind, int value) : kind_(kind), value_(value) {}

    Kind kind_ = Kind::None;
    int value_ = 0;
};

// The name of a Windows virtual-key code as a key on the on-screen keyboard shows it.
QString bindableKeyName(int code);

size_t qHash(const Config::InputRef &ref, size_t seed = 0) noexcept;
size_t qHash(const Config::Binding &binding, size_t seed = 0) noexcept;

} // namespace SteamInput
