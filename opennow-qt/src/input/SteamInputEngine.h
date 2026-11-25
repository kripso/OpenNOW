#pragma once

#include "input/SteamInputConfig.h"

#include <QList>
#include <QPointF>
#include <QSet>
#include <QString>
#include <QStringList>

#include <limits>
#include <map>
#include <optional>
#include <set>
#include <vector>

namespace SteamInput {

// The four ways a thumb can point on a pad's d-pad mode.
enum class Direction { Up, Down, Left, Right };

// Runs a layout: turns pad reports into what the host understands — a gamepad packet plus key,
// mouse-button, pointer and wheel input. It holds no connection or timer; the caller feeds it
// reports and the current time and sends what comes back.
class Engine {
public:
    struct Pad {
        quint16 buttons = 0;
        quint8 leftTrigger = 0;
        quint8 rightTrigger = 0;
        qint16 leftStickX = 0;
        qint16 leftStickY = 0;
        qint16 rightStickX = 0;
        qint16 rightStickY = 0;

        friend bool operator==(const Pad &, const Pad &) = default;
    };

    struct KeyEvent {
        quint16 virtualKey = 0;
        bool pressed = false;
        // Shift 0x01, Control 0x02, Alt 0x04, as held once this event has applied.
        quint16 modifiers = 0;

        friend bool operator==(const KeyEvent &, const KeyEvent &) = default;
    };

    struct MouseButtonEvent {
        int button = 0;
        bool pressed = false;

        friend bool operator==(const MouseButtonEvent &, const MouseButtonEvent &) = default;
    };

    struct Output {
        Pad pad;
        QList<KeyEvent> keys;
        QList<MouseButtonEvent> mouseButtons;
        // Pointer travel in screen direction: y grows downward.
        QPointF mouse;
        // 120 is one notch and positive scrolls up.
        int wheel = 0;
        // Sideways scrolling in the same units; positive scrolls right.
        int wheelX = 0;
        // Where to put the pointer, as a fraction of the screen from its top left.
        std::optional<QPointF> absolute;
        QList<Shortcut> shortcuts;

        friend bool operator==(const Output &, const Output &) = default;
    };

    // A radial or touch menu that is open on a stick or trackpad, for drawing over the game.
    struct Menu {
        Config::Source source = Config::Source::ButtonDiamond;
        bool radial = false;
        QString title;
        QStringList items;
        std::optional<int> selected;

        QString id() const { return sourceToken(source); }

        friend bool operator==(const Menu &, const Menu &) = default;
    };

    explicit Engine(Config config);

    const Config &config() const { return config_; }
    void setConfig(Config config);

    // The player's own scaling on top of whatever the layout asks for.
    Tuning tuning;

    // Menus currently open, after the latest report.
    const QList<Menu> &menus() const { return menus_; }

    // Whether the layout needs gyro readings from the pad.
    bool wantsGyro() const { return config_.usesGyro(); }

    // The name of the action set in use, when the layout has more than one.
    std::optional<QString> actionSetTitle() const;

    // Takes a new report. While `suspended` (the stream does not own the pad) everything is
    // released and only shortcuts are reported, so the pad can still close the overlay it opened.
    Output apply(const Report &next, double now, bool suspended = false);

    // Lets time pass between reports: sticks keep driving the pointer, long presses come due and
    // brief taps end.
    Output advance(double now);

    // Lets go of everything, for when the pad disconnects or the stream ends.
    Output releaseAll();

    static std::optional<int> radialItem(const Vector &value, int count);
    // The cell under the thumb, with items filling rows from the top left.
    static std::optional<int> gridItem(const Vector &value, int count);
    // The number of columns `gridItem` lays a touch menu out in.
    static int gridColumns(int count);

private:
    using Ref = Config::InputRef;
    using Binding = Config::Binding;
    using Activator = Config::Activator;
    using Group = Config::Group;
    using Source = Config::Source;
    using Mode = Config::Mode;

    struct Digital {
        bool down = false;
        bool soft = false;
    };

    struct Latched {
        Activator activator;
    };

    // One pressable input and the activators it took on when it was last pressed. They stay
    // until it is let go, so a layer that appears mid-press does not change what the press means.
    struct Slot {
        bool down = false;
        bool soft = false;
        double pressedAt = -std::numeric_limits<double>::infinity();
        double releasedAt = -std::numeric_limits<double>::infinity();
        bool doublePress = false;
        bool needsLatch = false;
        QList<Latched> activators;
        std::set<int> toggled;
    };

    struct Surface {
        std::optional<Vector> anchor;
        std::set<Direction> directions;
        std::optional<double> angle;
        double turned = 0;
        std::optional<int> menuItem;
        std::optional<int> menuGroup;
        bool clicked = false;
        Vector deflection;
        std::optional<double> flickAngle;
        double flickPending = 0;
        double flickTotal = 0;
        std::optional<QPointF> region;
    };

    struct Tap {
        QList<Binding> bindings;
        double until = 0;
    };

    void release(Output &output);
    const Group *groupFor(int id) const;
    std::vector<const Group *> stack(Source source) const;
    Mode modeOf(Source source) const;
    QList<Activator> resolve(const Ref &ref) const;
    std::optional<double> setting(const QString &key, Source source) const;
    Vector vectorOf(Source source) const;
    bool touched(Source source) const;
    std::map<Ref, Digital> physicalInputs();
    void evaluate(double now, bool fresh, Output &output);
    void tap(const QList<Activator> &activators, double now, Output &output);
    void evaluateSurface(Source source, double step, bool fresh, double now,
                         std::map<Ref, Digital> &digital, Vector &leftStick, Vector &rightStick,
                         QPointF &wheel, QList<Menu> &menus, Output &output);
    void evaluateGyro(const std::map<Ref, Digital> &digital, bool fresh, Vector &rightStick, Output &output);
    void setHeld(const QSet<quint16> &keys, const QSet<int> &mouseButtons, Output &output);
    quint16 modifierFlags() const;

    Config config_;
    int baseSet_ = 0;
    Report report_;
    std::map<Ref, Slot> slots_;
    std::set<Ref> physicalDown_;
    std::set<Source> softTriggers_;
    // Inputs held while the stream did not own the pad; ignored until they are let go.
    std::set<Ref> blocked_;
    QList<int> layers_;
    QList<int> heldLayers_;
    std::map<Source, int> modeShifts_;
    QSet<Binding> heldBindings_;
    QList<Tap> taps_;
    QSet<quint16> heldKeys_;
    QSet<int> heldMouseButtons_;
    std::map<Source, Surface> surfaces_;
    Vector gyroStick_;
    bool gyroHeld_ = false;
    bool gyroToggled_ = false;
    double wheelRemainder_ = 0;
    double wheelXRemainder_ = 0;
    std::optional<double> lastStep_;
    QList<Menu> menus_;
};

} // namespace SteamInput
