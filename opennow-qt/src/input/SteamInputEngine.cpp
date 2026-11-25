#include "input/SteamInputEngine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>
#include <tuple>
#include <utility>

// Each float operation rounds on its own, as the reference arithmetic does; a fused multiply-add
// would move the last bit of pointer and stick values.
#pragma clang fp contract(off)

namespace SteamInput {

namespace {

using Source = Config::Source;
using Mode = Config::Mode;
using Binding = Config::Binding;
using Activator = Config::Activator;
using Group = Config::Group;
using Ref = Config::InputRef;

constexpr std::array<Source, 11> allSources{
    Source::ButtonDiamond, Source::Dpad, Source::Joystick, Source::RightJoystick, Source::LeftTrackpad,
    Source::RightTrackpad, Source::LeftTrigger, Source::RightTrigger, Source::Gyro, Source::Switches,
    Source::System,
};

constexpr float softPull = 0.3f;
constexpr float softRelease = 0.2f;
constexpr float fullPull = 0.95f;
constexpr float stickDeadZone = 0.12f;
constexpr double stickMousePixelsPerSecond = 1080.0;
constexpr double stickWheelUnitsPerSecond = 720.0;
constexpr double padMouseCountsPerUnit = 600.0;
constexpr double padWheelUnitsPerUnit = 1200.0;
constexpr float padStickReach = 1.25f;
constexpr float padUnitsPerSecondForFullStick = 3.0f;
constexpr double gyroMouseCountsPerDegree = 20.0;
constexpr double gyroStickFullScaleDegreesPerSecond = 180.0;
constexpr double gyroSoftThresholdDegreesPerSecond = 1.0;
constexpr double maximumStep = 0.05;
constexpr int wheelNotch = 120;
constexpr double tapDuration = 0.04;
constexpr double defaultScrollAngle = 30.0;
constexpr float menuCentre = 0.3f;
constexpr float flickPress = 0.9f;
constexpr float flickRelease = 0.8f;
constexpr double flickDuration = 0.1;
constexpr float mouseJoystickMinimum = 0.15f;

constexpr double pi = std::numbers::pi;

// The gyro's rate in screen direction, in degrees per second.
struct ScreenRate {
    double x = 0;
    double y = 0;
};

// Squares the travel past the dead zone: fine near the centre, full speed at the rim.
Vector curved(const Vector &value)
{
    const float length = value.length();
    if (!std::isfinite(length) || !(length > stickDeadZone)) return {};
    const float scaled = std::min((length - stickDeadZone) / (1 - stickDeadZone), 1.0f);
    const float factor = scaled * scaled / length;
    return Vector{value.x * factor, value.y * factor};
}

std::set<Direction> heldDirections(const Vector &value, const std::set<Direction> &previous,
                                   float press, float release)
{
    std::set<Direction> held;
    const auto threshold = [&previous, press, release](Direction direction) {
        return previous.contains(direction) ? release : press;
    };
    if (value.y >= threshold(Direction::Up)) held.insert(Direction::Up);
    if (value.y <= -threshold(Direction::Down)) held.insert(Direction::Down);
    if (value.x <= -threshold(Direction::Left)) held.insert(Direction::Left);
    if (value.x >= threshold(Direction::Right)) held.insert(Direction::Right);
    return held;
}

QString directionInput(Direction direction)
{
    switch (direction) {
    case Direction::Up: return QStringLiteral("dpad_north");
    case Direction::Down: return QStringLiteral("dpad_south");
    case Direction::Left: return QStringLiteral("dpad_west");
    case Direction::Right: return QStringLiteral("dpad_east");
    }
    return {};
}

// Degrees per second in screen direction, with resting noise faded out near zero.
ScreenRate gyroScreenRate(float pitch, float yaw)
{
    const double x = -static_cast<double>(yaw) * 180 / pi;
    const double y = -static_cast<double>(pitch) * 180 / pi;
    const double magnitude = std::sqrt(x * x + y * y);
    if (!std::isfinite(magnitude) || !(magnitude > 0)) return {};
    const double scale = std::min(1.0, magnitude / gyroSoftThresholdDegreesPerSecond);
    return ScreenRate{x * scale, y * scale};
}

quint8 byteOf(float value)
{
    const int rounded = static_cast<int>(std::round(value * 255));
    return static_cast<quint8>(std::clamp(rounded, 0, 255));
}

std::pair<qint16, qint16> axesOf(const Vector &value)
{
    const float length = value.length();
    if (!std::isfinite(length)) return {0, 0};
    const float factor = length > 1 ? 1 / length : 1;
    const auto axis = [factor](float component) {
        return static_cast<qint16>(std::clamp(std::round(component * factor * 32767), -32767.0f, 32767.0f));
    };
    return {axis(value.x), axis(value.y)};
}

quint16 modifierFlag(quint16 virtualKey)
{
    switch (virtualKey) {
    case 0x10:
    case 0xa0:
    case 0xa1: return 0x01;
    case 0x11:
    case 0xa2:
    case 0xa3: return 0x02;
    case 0x12:
    case 0xa4:
    case 0xa5: return 0x04;
    default: return 0;
    }
}

// A layer only lists what it changes: a setting comes from the topmost group in the source's
// current mode that has it.
std::optional<double> lookupSetting(const std::vector<const Group *> &groups, const QString &key)
{
    if (groups.empty()) return std::nullopt;
    const Mode mode = groups.front()->mode;
    for (const Group *group : groups) {
        if (group->mode != mode) continue;
        const auto found = group->settings.find(key);
        if (found != group->settings.end()) return found->second;
    }
    return std::nullopt;
}

} // namespace

Engine::Engine(Config config)
    : config_(std::move(config))
    , baseSet_(config_.defaultSet)
{
}

void Engine::setConfig(Config config)
{
    if (config == config_) return;
    config_ = std::move(config);
    baseSet_ = config_.defaultSet;
    layers_.clear();
    heldLayers_.clear();
    modeShifts_.clear();
    for (auto &[unusedKey, slot] : slots_) {
        slot.activators.clear();
        slot.toggled.clear();
        slot.needsLatch = true;
    }
}

std::optional<QString> Engine::actionSetTitle() const
{
    int named = 0;
    for (const auto &[unusedKey, set] : config_.sets) {
        if (!set.isLayer) ++named;
    }
    if (named <= 1) return std::nullopt;
    const auto found = config_.sets.find(baseSet_);
    if (found == config_.sets.end()) return std::nullopt;
    return found->second.title;
}

Engine::Output Engine::apply(const Report &next, double now, bool suspended)
{
    report_ = next;
    Output output;
    if (!suspended) {
        evaluate(now, true, output);
        return output;
    }

    std::map<Ref, Digital> digital = physicalInputs();
    for (const auto &[ref, state] : digital) {
        if (!state.down) continue;
        if (!physicalDown_.contains(ref)) {
            for (const Activator &activator : resolve(ref)) {
                if (activator.kind != Activator::Kind::FullPress && activator.kind != Activator::Kind::StartPress) {
                    continue;
                }
                for (const Binding &binding : activator.bindings) {
                    if (binding.kind == Binding::Kind::Shortcut && !output.shortcuts.contains(binding.shortcutAction()))
                        output.shortcuts.append(binding.shortcutAction());
                }
            }
        }
        blocked_.insert(ref);
    }
    physicalDown_.clear();
    for (const auto &[ref, state] : digital) {
        if (state.down) physicalDown_.insert(ref);
    }
    release(output);
    return output;
}

Engine::Output Engine::advance(double now)
{
    Output output;
    evaluate(now, false, output);
    return output;
}

Engine::Output Engine::releaseAll()
{
    Output output;
    release(output);
    report_ = Report{};
    physicalDown_.clear();
    blocked_.clear();
    slots_.clear();
    baseSet_ = config_.defaultSet;
    layers_.clear();
    gyroToggled_ = false;
    return output;
}

void Engine::release(Output &output)
{
    setHeld({}, {}, output);
    for (auto &[unusedKey, slot] : slots_) {
        slot.down = false;
        slot.soft = false;
        slot.activators.clear();
    }
    heldBindings_.clear();
    heldLayers_.clear();
    modeShifts_.clear();
    taps_.clear();
    surfaces_.clear();
    softTriggers_.clear();
    menus_.clear();
    gyroStick_ = Vector{};
    gyroHeld_ = false;
    wheelRemainder_ = 0;
    wheelXRemainder_ = 0;
    lastStep_.reset();
    output.pad = Pad{};
}

// MARK: Layout lookup

const Group *Engine::groupFor(int id) const
{
    const auto found = config_.groups.find(id);
    return found == config_.groups.end() ? nullptr : &found->second;
}

// The groups that apply to a source, topmost first: a mode shift, then layers, then the set.
std::vector<const Group *> Engine::stack(Source source) const
{
    std::vector<const Group *> result;
    if (const auto shifted = modeShifts_.find(source); shifted != modeShifts_.end()) {
        if (const Group *group = groupFor(shifted->second)) result.push_back(group);
    }
    const QList<int> layers = layers_ + heldLayers_;
    for (qsizetype index = layers.size(); index-- > 0;) {
        const auto set = config_.sets.find(layers[index]);
        if (set == config_.sets.end()) continue;
        const auto id = set->second.groups.find(source);
        if (id == set->second.groups.end()) continue;
        if (const Group *group = groupFor(id->second)) result.push_back(group);
    }
    const auto base = config_.sets.find(baseSet_);
    if (base != config_.sets.end()) {
        const auto id = base->second.groups.find(source);
        if (id != base->second.groups.end()) {
            if (const Group *group = groupFor(id->second)) result.push_back(group);
        }
    }
    return result;
}

Mode Engine::modeOf(Source source) const
{
    const auto groups = stack(source);
    return groups.empty() ? Mode::Disabled : groups.front()->mode;
}

// A layer only lists what it changes, so anything it leaves out comes from below, as long as the
// source is still in the same mode there.
QList<Activator> Engine::resolve(const Ref &ref) const
{
    const auto groups = stack(ref.source);
    if (groups.empty()) return {};
    const Mode mode = groups.front()->mode;
    for (const Group *group : groups) {
        if (group->mode != mode) continue;
        const auto found = group->inputs.find(ref.input);
        if (found != group->inputs.end()) return found->second;
    }
    return {};
}

std::optional<double> Engine::setting(const QString &key, Source source) const
{
    return lookupSetting(stack(source), key);
}

// MARK: Evaluation

Vector Engine::vectorOf(Source source) const
{
    switch (source) {
    case Source::Joystick: return report_.leftStick;
    case Source::RightJoystick: return report_.rightStick;
    case Source::LeftTrackpad: return report_.leftPad;
    case Source::RightTrackpad: return report_.rightPad;
    default: return Vector{};
    }
}

bool Engine::touched(Source source) const
{
    switch (source) {
    case Source::LeftTrackpad: return report_.buttons.testFlag(Button::LeftPadTouch);
    case Source::RightTrackpad: return report_.buttons.testFlag(Button::RightPadTouch);
    default: return true;
    }
}

// Everything that is simply pressed or not, read straight from the report.
std::map<Ref, Engine::Digital> Engine::physicalInputs()
{
    std::map<Ref, Digital> result;
    const auto set = [this, &result](Source source, const char *input, Button button) {
        const bool down = report_.buttons.testFlag(button);
        result[Ref{source, QString::fromLatin1(input)}] = Digital{down, down};
    };
    set(Source::ButtonDiamond, "button_a", Button::A);
    set(Source::ButtonDiamond, "button_b", Button::B);
    set(Source::ButtonDiamond, "button_x", Button::X);
    set(Source::ButtonDiamond, "button_y", Button::Y);
    set(Source::Switches, "button_escape", Button::Menu);
    set(Source::Switches, "button_menu", Button::View);
    set(Source::Switches, "left_bumper", Button::LeftBumper);
    set(Source::Switches, "right_bumper", Button::RightBumper);
    set(Source::Switches, "button_back_left", Button::L5);
    set(Source::Switches, "button_back_left_upper", Button::L4);
    set(Source::Switches, "button_back_right", Button::R5);
    set(Source::Switches, "button_back_right_upper", Button::R4);
    set(Source::Switches, "button_capture", Button::QuickAccess);
    set(Source::Dpad, "dpad_north", Button::DpadUp);
    set(Source::Dpad, "dpad_south", Button::DpadDown);
    set(Source::Dpad, "dpad_west", Button::DpadLeft);
    set(Source::Dpad, "dpad_east", Button::DpadRight);
    set(Source::Joystick, "click", Button::LeftStickClick);
    set(Source::Joystick, "touch", Button::LeftStickTouch);
    set(Source::RightJoystick, "click", Button::RightStickClick);
    set(Source::RightJoystick, "touch", Button::RightStickTouch);
    set(Source::LeftTrackpad, "click", Button::LeftPadClick);
    set(Source::LeftTrackpad, "touch", Button::LeftPadTouch);
    set(Source::RightTrackpad, "click", Button::RightPadClick);
    set(Source::RightTrackpad, "touch", Button::RightPadTouch);
    set(Source::System, "steam", Button::Steam);
    set(Source::System, "left_grip", Button::LeftGrip);
    set(Source::System, "right_grip", Button::RightGrip);

    struct TriggerInput {
        Source source;
        float value;
        Button click;
    };
    const TriggerInput triggers[] = {
        {Source::LeftTrigger, report_.leftTrigger, Button::LeftTriggerClick},
        {Source::RightTrigger, report_.rightTrigger, Button::RightTriggerClick},
    };
    for (const TriggerInput &trigger : triggers) {
        // Hysteresis: a pull that is already soft stays soft until it falls below the lower mark.
        const float threshold = softTriggers_.contains(trigger.source) ? softRelease : softPull;
        const bool soft = trigger.value >= threshold;
        if (soft) {
            softTriggers_.insert(trigger.source);
        } else {
            softTriggers_.erase(trigger.source);
        }
        const bool full = report_.buttons.testFlag(trigger.click) || trigger.value >= fullPull;
        result[Ref{trigger.source, QStringLiteral("click")}] = Digital{full, soft};
        result[Ref{trigger.source, QStringLiteral("edge")}] = Digital{soft, soft};
    }
    return result;
}

void Engine::evaluate(double now, bool fresh, Output &output)
{
    const double step = lastStep_ ? std::min(std::max(now - *lastStep_, 0.0), maximumStep) : 0.0;
    lastStep_ = now;

    std::map<Ref, Digital> digital = physicalInputs();
    physicalDown_.clear();
    for (const auto &[ref, state] : digital) {
        if (state.down) physicalDown_.insert(ref);
    }
    for (auto it = blocked_.begin(); it != blocked_.end();) {
        if (physicalDown_.contains(*it)) {
            ++it;
        } else {
            it = blocked_.erase(it);
        }
    }
    for (const Ref &ref : blocked_) digital[ref] = Digital{false, false};

    Vector leftStick;
    Vector rightStick;
    float leftTrigger = 0;
    float rightTrigger = 0;
    QPointF wheel;
    QList<Menu> openMenus;

    for (const Source source : allSources) {
        if (!isSurface(source)) continue;
        evaluateSurface(source, step, fresh, now, digital, leftStick, rightStick, wheel, openMenus, output);
    }
    menus_ = openMenus;

    const std::pair<Source, float> analogTriggers[] = {
        {Source::LeftTrigger, report_.leftTrigger},
        {Source::RightTrigger, report_.rightTrigger},
    };
    for (const auto &[source, value] : analogTriggers) {
        if (modeOf(source) != Mode::Trigger || blocked_.contains(Ref{source, QStringLiteral("edge")})) continue;
        const auto outputTrigger = setting(QStringLiteral("output_trigger"), source);
        if (outputTrigger == 1.0) leftTrigger = std::max(leftTrigger, value);
        if (outputTrigger == 2.0) rightTrigger = std::max(rightTrigger, value);
    }

    evaluateGyro(digital, fresh, rightStick, output);

    // Slots: latch on press, then work out which activators are in effect.
    QList<Binding> held;
    std::set<Ref> refs;
    for (const auto &[ref, unusedState] : digital) refs.insert(ref);
    for (const auto &[ref, unusedSlot] : slots_) refs.insert(ref);
    for (const Ref &ref : refs) {
        const auto stateFound = digital.find(ref);
        const Digital state = stateFound == digital.end() ? Digital{} : stateFound->second;
        const auto slotFound = slots_.find(ref);
        Slot slot = slotFound == slots_.end() ? Slot{} : slotFound->second;
        const bool engaged = state.down || state.soft;
        const bool wasEngaged = slot.down || slot.soft;
        if (engaged && (!wasEngaged || slot.needsLatch)) {
            const bool silent = wasEngaged;
            slot.activators.clear();
            for (const Activator &activator : resolve(ref)) {
                Latched latched;
                latched.activator = activator;
                slot.activators.append(latched);
            }
            slot.needsLatch = false;
            if (!silent) {
                std::optional<double> window;
                for (const auto &latched : slot.activators) {
                    if (latched.activator.kind != Activator::Kind::DoublePress) continue;
                    const double time = latched.activator.doubleTapTime;
                    window = window ? std::max(*window, time) : time;
                }
                slot.doublePress = window ? (now - slot.pressedAt <= *window) : false;
                slot.pressedAt = now;
            }
        }
        if (state.down && !slot.down && !slot.needsLatch) {
            for (qsizetype index = 0; index < slot.activators.size(); ++index) {
                const Activator activator = slot.activators[index].activator;
                if (activator.kind == Activator::Kind::StartPress) tap({activator}, now, output);
                if (activator.kind == Activator::Kind::FullPress && activator.toggle) {
                    if (slot.toggled.contains(static_cast<int>(index))) {
                        slot.toggled.erase(static_cast<int>(index));
                    } else {
                        slot.toggled.insert(static_cast<int>(index));
                    }
                }
            }
        }
        if (!state.down && slot.down) {
            slot.releasedAt = now;
            QList<Activator> releases;
            for (const auto &latched : slot.activators) {
                if (latched.activator.kind == Activator::Kind::Release) releases.append(latched.activator);
            }
            tap(releases, now, output);
        }
        slot.down = state.down;
        slot.soft = state.soft;
        for (qsizetype index = 0; index < slot.activators.size(); ++index) {
            const Activator &activator = slot.activators[index].activator;
            bool active = false;
            switch (activator.kind) {
            case Activator::Kind::FullPress:
                if (activator.toggle) {
                    active = slot.toggled.contains(static_cast<int>(index));
                } else {
                    bool pressed = state.down && now - slot.pressedAt >= activator.delayStart;
                    if (pressed && activator.holdRepeats && activator.repeatInterval > 0) {
                        const auto presses = static_cast<long long>((now - slot.pressedAt) / activator.repeatInterval);
                        pressed = presses % 2 == 0;
                    }
                    active = pressed
                             || (!state.down && activator.delayEnd > 0 && now - slot.releasedAt < activator.delayEnd);
                }
                break;
            case Activator::Kind::SoftPress:
                active = state.soft;
                break;
            case Activator::Kind::LongPress:
                active = state.down && now - slot.pressedAt >= activator.longPressTime;
                break;
            case Activator::Kind::DoublePress:
                active = state.down && slot.doublePress;
                break;
            case Activator::Kind::StartPress:
            case Activator::Kind::Release:
                active = false;
                break;
            }
            if (active) held += activator.bindings;
        }
        bool lingering = false;
        for (const auto &latched : slot.activators) {
            if (latched.activator.delayEnd > 0 && now - slot.releasedAt < latched.activator.delayEnd) lingering = true;
        }
        if (!engaged && !lingering && slot.toggled.empty()) slot.activators.clear();
        slots_[ref] = slot;
    }

    QList<Tap> liveTaps;
    for (const Tap &tapped : taps_) {
        if (tapped.until > now) liveTaps.append(tapped);
    }
    taps_ = liveTaps;
    for (const Tap &tapped : taps_) held += tapped.bindings;

    // Bindings: what is newly held acts once, the rest acts for as long as it is held.
    Pad next;
    double leftTriggerValue = leftTrigger;
    double rightTriggerValue = rightTrigger;
    QSet<quint16> keys;
    QSet<int> mouseButtons;
    QList<int> nextLayers;
    std::map<Source, int> nextShifts;
    const QSet<Binding> heldSet(held.begin(), held.end());
    for (const Binding &binding : held) {
        const bool isNew = !heldBindings_.contains(binding);
        switch (binding.kind) {
        case Binding::Kind::Key:
            keys.insert(static_cast<quint16>(binding.value));
            break;
        case Binding::Kind::MouseButton:
            mouseButtons.insert(binding.value);
            break;
        case Binding::Kind::Pad:
            if (binding.padButton() == PadButton::Lt) {
                leftTriggerValue = 1;
            } else if (binding.padButton() == PadButton::Rt) {
                rightTriggerValue = 1;
            } else {
                next.buttons |= padButtonMask(binding.padButton());
            }
            break;
        case Binding::Kind::HoldLayer:
            if (!nextLayers.contains(binding.value)) nextLayers.append(binding.value);
            break;
        case Binding::Kind::ModeShift:
            nextShifts[binding.source] = binding.value;
            break;
        case Binding::Kind::Wheel:
            if (isNew) output.wheel += binding.value * wheelNotch;
            break;
        case Binding::Kind::Shortcut:
            if (isNew && !output.shortcuts.contains(binding.shortcutAction())) {
                output.shortcuts.append(binding.shortcutAction());
            }
            break;
        case Binding::Kind::ChangeSet: {
            const auto target = config_.sets.find(binding.value);
            if (isNew && target != config_.sets.end() && !target->second.isLayer) {
                baseSet_ = binding.value;
                layers_.clear();
            }
            break;
        }
        case Binding::Kind::AddLayer:
            if (isNew && config_.sets.contains(binding.value) && !layers_.contains(binding.value)) {
                layers_.append(binding.value);
            }
            break;
        case Binding::Kind::RemoveLayer:
            if (isNew) layers_.removeAll(binding.value);
            break;
        }
    }
    heldBindings_ = heldSet;
    heldLayers_.clear();
    for (const int layer : nextLayers) {
        if (config_.sets.contains(layer)) heldLayers_.append(layer);
    }
    modeShifts_ = nextShifts;

    const double scroll = static_cast<double>(tuning.scroll) / 100;
    wheelRemainder_ += wheel.y() * scroll;
    const double wholeWheel = std::trunc(wheelRemainder_);
    wheelRemainder_ -= wholeWheel;
    output.wheel += static_cast<int>(wholeWheel);
    wheelXRemainder_ += wheel.x() * scroll;
    const double wholeWheelX = std::trunc(wheelXRemainder_);
    wheelXRemainder_ -= wholeWheelX;
    output.wheelX += static_cast<int>(wholeWheelX);

    next.leftTrigger = byteOf(static_cast<float>(leftTriggerValue));
    next.rightTrigger = byteOf(static_cast<float>(rightTriggerValue));
    std::tie(next.leftStickX, next.leftStickY) = axesOf(leftStick);
    std::tie(next.rightStickX, next.rightStickY) = axesOf(rightStick);
    output.pad = next;
    setHeld(keys, mouseButtons, output);
}

// Presses bindings briefly, for things that happen at a moment rather than while held.
void Engine::tap(const QList<Activator> &activators, double now, Output &output)
{
    for (const Activator &activator : activators) {
        QList<Binding> bindings;
        for (const Binding &binding : activator.bindings) {
            // Wheel notches are counted one by one; holding them would merge quick turns.
            if (binding.kind == Binding::Kind::Wheel) {
                output.wheel += binding.value * wheelNotch;
            } else {
                bindings.append(binding);
            }
        }
        if (!bindings.isEmpty()) taps_.append(Tap{bindings, now + tapDuration});
    }
}

void Engine::evaluateSurface(Source source, double step, bool fresh, double now,
                             std::map<Ref, Digital> &digital, Vector &leftStick, Vector &rightStick,
                             QPointF &wheel, QList<Menu> &menus, Output &output)
{
    const Mode mode = modeOf(source);
    const bool isPad = isTrackpad(source);
    const bool isTouched = touched(source);
    const Vector position = vectorOf(source);
    const auto surfaceFound = surfaces_.find(source);
    Surface surface = surfaceFound == surfaces_.end() ? Surface{} : surfaceFound->second;
    const std::optional<Vector> previous = surface.anchor;
    if (isPad) surface.anchor = isTouched ? std::optional<Vector>(position) : std::nullopt;
    const double scale = setting(QStringLiteral("sensitivity"), source).value_or(100) / 100;
    const Ref clickRef{source, QStringLiteral("click")};
    const auto clickedFound = digital.find(clickRef);
    const bool clicked = clickedFound != digital.end() && clickedFound->second.down;
    std::set<Direction> directions;
    Vector deflection;

    const auto addStick = [&leftStick, &rightStick](const Vector &value, bool right) {
        Vector &target = right ? rightStick : leftStick;
        target.x += value.x;
        target.y += value.y;
    };
    const auto mouseFromSwipe = [&]() {
        if (!fresh || !isTouched || !previous) return;
        const double counts = padMouseCountsPerUnit * scale * static_cast<double>(tuning.trackpadMouse) / 100;
        output.mouse.rx() += static_cast<double>(position.x - previous->x) * counts;
        output.mouse.ry() -= static_cast<double>(position.y - previous->y) * counts;
    };
    const auto mouseFromDeflection = [&]() {
        const Vector curvedPosition = curved(position);
        const double speed = stickMousePixelsPerSecond * scale * step * static_cast<double>(tuning.stickMouse) / 100;
        output.mouse.rx() += static_cast<double>(curvedPosition.x) * speed;
        output.mouse.ry() -= static_cast<double>(curvedPosition.y) * speed;
    };
    const auto edgeRef = [source]() { return Ref{source, QStringLiteral("edge")}; };

    switch (mode) {
    case Mode::FlickStick: {
        // Pushing the stick out turns the view to face that way; sweeping it round turns the view by
        // the same angle. Both become sideways pointer travel.
        const double countsPerRadian = static_cast<double>(tuning.flickTurn) / (2 * pi);
        const float threshold = surface.flickAngle ? flickRelease : flickPress;
        if (isTouched && position.length() >= threshold) {
            const double angle = std::atan2(static_cast<double>(position.x), static_cast<double>(position.y));
            if (surface.flickAngle) {
                double change = angle - *surface.flickAngle;
                if (change > pi) change -= 2 * pi;
                if (change < -pi) change += 2 * pi;
                output.mouse.rx() += change * countsPerRadian;
            } else {
                surface.flickTotal = angle * countsPerRadian;
                surface.flickPending = surface.flickTotal;
            }
            surface.flickAngle = angle;
        } else {
            surface.flickAngle.reset();
        }
        if (surface.flickPending != 0) {
            const double portion = std::abs(surface.flickTotal) * step / flickDuration;
            const double spent = surface.flickPending < 0 ? std::max(surface.flickPending, -portion)
                                                          : std::min(surface.flickPending, portion);
            surface.flickPending -= spent;
            output.mouse.rx() += spent;
        }
        break;
    }
    case Mode::MouseRegion: {
        // The surface stands for a rectangle on the screen, centred where the layout says.
        if (fresh && isTouched && (isPad || position.length() >= stickDeadZone)) {
            const double half = setting(QStringLiteral("scale"), source).value_or(100) / 100 / 2;
            const double centreX = setting(QStringLiteral("position_x"), source).value_or(50) / 100;
            const double centreY = setting(QStringLiteral("position_y"), source).value_or(50) / 100;
            const QPointF point(
                std::min(std::max(centreX + static_cast<double>(position.x) * half, 0.0), 1.0),
                std::min(std::max(centreY - static_cast<double>(position.y) * half, 0.0), 1.0));
            if (!surface.region || *surface.region != point) {
                surface.region = point;
                output.absolute = point;
            }
        } else if (!isTouched) {
            surface.region.reset();
        }
        const float edge = static_cast<float>(setting(QStringLiteral("edge_binding_radius"), source).value_or(29500) / 32767);
        const bool outer = isTouched && position.length() >= edge;
        digital[edgeRef()] = Digital{outer, outer};
        break;
    }
    case Mode::Scroll2D: {
        if (isPad) {
            if (fresh && isTouched && previous) {
                wheel.rx() += static_cast<double>(position.x - previous->x) * padWheelUnitsPerUnit * scale;
                wheel.ry() += static_cast<double>(position.y - previous->y) * padWheelUnitsPerUnit * scale;
            }
        } else {
            const Vector curvedPosition = curved(position);
            wheel.rx() += static_cast<double>(curvedPosition.x) * stickWheelUnitsPerSecond * scale * step;
            wheel.ry() += static_cast<double>(curvedPosition.y) * stickWheelUnitsPerSecond * scale * step;
        }
        break;
    }
    case Mode::JoystickMove:
    case Mode::JoystickCamera: {
        const bool defaultsRight = mode != Mode::JoystickMove || source == Source::RightJoystick
                                   || source == Source::RightTrackpad;
        const auto target = setting(QStringLiteral("output_joystick"), source);
        if (target == 2.0) {
            if (isPad) {
                mouseFromSwipe();
            } else {
                mouseFromDeflection();
            }
        } else {
            Vector value = position;
            if (isPad) {
                const float reach = static_cast<float>(scale);
                value = isTouched ? Vector{position.x * padStickReach * reach, position.y * padStickReach * reach}
                                  : Vector{};
            }
            addStick(value, target ? *target == 1.0 : defaultsRight);
        }
        const float edge = static_cast<float>(setting(QStringLiteral("edge_binding_radius"), source).value_or(29500) / 32767);
        const bool outer = isTouched && position.length() >= edge;
        digital[edgeRef()] = Digital{outer, outer};
        break;
    }
    case Mode::JoystickMouse:
    case Mode::AbsoluteMouse:
        if (isPad) {
            mouseFromSwipe();
        } else {
            mouseFromDeflection();
        }
        break;
    case Mode::MouseJoystick:
        if (isPad) {
            // The faster the thumb moves, the further the stick is pushed. The push is smoothed over
            // neighbouring reports and never falls inside a game's dead zone.
            if (fresh && isTouched && previous && step > 0) {
                const float speed = static_cast<float>(scale) * static_cast<float>(tuning.trackpadMouse) / 100
                                    / (static_cast<float>(step) * padUnitsPerSecondForFullStick);
                Vector target{(position.x - previous->x) * speed, (position.y - previous->y) * speed};
                const float length = target.length();
                if (length > 0.001f) {
                    const float pushed = std::min(mouseJoystickMinimum + length * (1 - mouseJoystickMinimum), 1.0f);
                    target = Vector{target.x / length * pushed, target.y / length * pushed};
                } else {
                    target = Vector{};
                }
                deflection = Vector{(surface.deflection.x + target.x) / 2, (surface.deflection.y + target.y) / 2};
                if (deflection.length() < 0.02f) deflection = Vector{};
            } else if (!fresh && isTouched) {
                deflection = surface.deflection;
            }
            addStick(deflection, true);
        } else {
            addStick(position, true);
        }
        break;
    case Mode::LinearScroll:
        if (isPad) {
            if (fresh && isTouched && previous) {
                wheel.ry() += static_cast<double>(position.y - previous->y) * padWheelUnitsPerUnit * scale;
            }
        } else {
            wheel.ry() += static_cast<double>(curved(position).y) * stickWheelUnitsPerSecond * scale * step;
        }
        break;
    case Mode::ScrollWheel:
        // Circling the pad or stick turns the wheel a step for every so many degrees.
        if (isTouched && position.length() >= menuCentre) {
            const double angle = std::atan2(static_cast<double>(position.x), static_cast<double>(position.y));
            if (surface.angle) {
                double change = angle - *surface.angle;
                if (change > pi) change -= 2 * pi;
                if (change < -pi) change += 2 * pi;
                surface.turned += change * 180 / pi;
                const double stepAngle = std::max(setting(QStringLiteral("scroll_angle"), source).value_or(defaultScrollAngle), 5.0);
                while (std::abs(surface.turned) >= stepAngle) {
                    const bool clockwise = surface.turned > 0;
                    surface.turned += clockwise ? -stepAngle : stepAngle;
                    tap(resolve(Ref{source, clockwise ? QStringLiteral("scroll_clockwise")
                                                      : QStringLiteral("scroll_counterclockwise")}),
                        now, output);
                }
            }
            surface.angle = angle;
        } else {
            surface.angle.reset();
            surface.turned = 0;
        }
        break;
    case Mode::Dpad: {
        const bool requiresClick = setting(QStringLiteral("requires_click"), source) == 1.0;
        if (isTouched && (!requiresClick || clicked)) {
            const auto deadzone = setting(QStringLiteral("deadzone"), source);
            const float press = deadzone ? static_cast<float>(*deadzone / 32767) : (isPad ? 0.3f : 0.5f);
            directions = heldDirections(position, surface.directions, press, press * 0.7f);
        }
        if (requiresClick) digital[clickRef] = Digital{false, false};
        for (const Direction direction : {Direction::Up, Direction::Down, Direction::Left, Direction::Right}) {
            const bool down = directions.contains(direction);
            digital[Ref{source, directionInput(direction)}] = Digital{down, down};
        }
        break;
    }
    case Mode::RadialMenu:
    case Mode::TouchMenu: {
        const auto groups = stack(source);
        if (groups.empty()) break;
        const Group *group = groups.front();
        const QString prefix = QStringLiteral("touch_menu_button_");
        int highest = -1;
        for (const auto &[key, unusedActivators] : group->inputs) {
            if (!key.startsWith(prefix)) continue;
            if (const auto index = parseInteger(key.mid(prefix.size()))) {
                highest = std::max(highest, static_cast<int>(*index));
            }
        }
        const int count = highest + 1;
        if (count <= 0) break;
        std::optional<int> selected;
        if (isTouched) {
            selected = mode == Mode::RadialMenu ? radialItem(position, count) : gridItem(position, count);
        }
        // Trackpads choose on a click unless the layout says on release; sticks on release.
        const auto fireType = setting(QStringLiteral("touchmenu_button_fire_type"), source);
        const bool onClick = fireType ? *fireType == 0 : isPad;
        const std::optional<int> item = selected ? selected : surface.menuItem;
        bool fire = false;
        if (onClick) {
            fire = clicked && !surface.clicked && selected.has_value();
        } else {
            fire = !selected && surface.menuItem.has_value() && surface.menuGroup == group->id;
        }
        if (fire && item) {
            tap(resolve(Ref{source, QStringLiteral("touch_menu_button_%1").arg(*item)}), now, output);
        }
        digital[clickRef] = Digital{false, false};
        surface.menuItem = selected;
        surface.menuGroup = group->id;
        if (selected || (isPad && isTouched)) {
            QStringList items;
            for (int index = 0; index < count; ++index) {
                const auto found = group->inputs.find(QStringLiteral("touch_menu_button_%1").arg(index));
                const bool labelled = found != group->inputs.end() && !found->second.isEmpty();
                items.append(labelled ? found->second.first().displayLabel() : QString());
            }
            Menu menu;
            menu.source = source;
            menu.radial = mode == Mode::RadialMenu;
            menu.title = group->name;
            menu.items = items;
            menu.selected = selected;
            menus.append(menu);
        }
        break;
    }
    case Mode::FourButtons:
    case Mode::Switches:
    case Mode::SingleButton:
    case Mode::Trigger:
    case Mode::GyroToMouse:
    case Mode::GyroToJoystick:
    case Mode::Disabled:
        break;
    }

    if (mode != Mode::FlickStick) {
        surface.flickAngle.reset();
        surface.flickPending = 0;
    }
    if (mode != Mode::RadialMenu && mode != Mode::TouchMenu) {
        // Leaving a menu with an item still chosen picks it, as when a mode shift is let go.
        if (surface.menuItem && surface.menuGroup) {
            const auto group = config_.groups.find(*surface.menuGroup);
            if (group != config_.groups.end()) {
                const auto fireType = group->second.settings.find(QStringLiteral("touchmenu_button_fire_type"));
                const bool onClick = fireType != group->second.settings.end() ? fireType->second == 0 : isPad;
                const auto activators = group->second.inputs.find(QStringLiteral("touch_menu_button_%1").arg(*surface.menuItem));
                if (!onClick && activators != group->second.inputs.end()) tap(activators->second, now, output);
            }
        }
        surface.menuItem.reset();
        surface.menuGroup.reset();
    }
    if (mode == Mode::Disabled) {
        digital[clickRef] = Digital{false, false};
        digital[Ref{source, QStringLiteral("touch")}] = Digital{false, false};
    }
    surface.directions = directions;
    surface.deflection = deflection;
    surface.clicked = clicked;
    surfaces_[source] = surface;
}

void Engine::evaluateGyro(const std::map<Ref, Digital> &digital, bool fresh, Vector &rightStick, Output &output)
{
    const auto groups = stack(Source::Gyro);
    if (groups.empty() || groups.front()->mode == Mode::Disabled) {
        gyroStick_ = Vector{};
        return;
    }
    const Group *group = groups.front();
    const bool asMouse = group->mode == Mode::GyroToMouse || group->mode == Mode::AbsoluteMouse
                         || group->mode == Mode::JoystickMouse;
    bool held = false;
    for (const Ref &activator : group->gyroActivators) {
        const auto found = digital.find(activator);
        if (found != digital.end() && found->second.soft) {
            held = true;
            break;
        }
    }
    if (held && !gyroHeld_) gyroToggled_ = !gyroToggled_;
    gyroHeld_ = held;

    bool active = true;
    if (!group->gyroActivators.isEmpty()) {
        switch (group->gyroActivation) {
        case Config::GyroActivation::WhileHeld: active = held; break;
        case Config::GyroActivation::WhileReleased: active = !held; break;
        case Config::GyroActivation::Toggle: active = gyroToggled_; break;
        }
    }
    if (!active) {
        gyroStick_ = Vector{};
    } else if (fresh && report_.gyroInterval > 0) {
        const ScreenRate rate = gyroScreenRate(report_.gyroPitch, report_.gyroYaw);
        const auto sensitivity = group->settings.find(QStringLiteral("sensitivity"));
        const double sensitivityValue = sensitivity != group->settings.end() ? sensitivity->second : 100;
        const double scale = sensitivityValue / 100 * static_cast<double>(tuning.gyro) / 100;
        if (asMouse) {
            const double interval = std::min(report_.gyroInterval, maximumStep);
            output.mouse.rx() += rate.x * interval * gyroMouseCountsPerDegree * scale;
            output.mouse.ry() += rate.y * interval * gyroMouseCountsPerDegree * scale;
        } else {
            // Screen y grows downward and a stick's grows upward.
            gyroStick_ = Vector{
                static_cast<float>(rate.x * scale / gyroStickFullScaleDegreesPerSecond),
                static_cast<float>(-rate.y * scale / gyroStickFullScaleDegreesPerSecond),
            };
        }
    }
    if (!asMouse) {
        rightStick.x += gyroStick_.x;
        rightStick.y += gyroStick_.y;
    }
}

// Emits the transitions between what was held and what should be. Modifier keys go down first and
// come up last so a chord such as Shift+1 arrives as one.
void Engine::setHeld(const QSet<quint16> &keys, const QSet<int> &mouseButtons, Output &output)
{
    const auto order = [](QList<quint16> codes, bool modifiersFirst) {
        std::sort(codes.begin(), codes.end(), [modifiersFirst](quint16 a, quint16 b) {
            const bool left = modifierFlag(a) != 0;
            const bool right = modifierFlag(b) != 0;
            if (left != right) return left == modifiersFirst;
            return a < b;
        });
        return codes;
    };

    QList<quint16> releasing;
    for (const quint16 code : heldKeys_) {
        if (!keys.contains(code)) releasing.append(code);
    }
    for (const quint16 code : order(releasing, false)) {
        heldKeys_.remove(code);
        output.keys.append(KeyEvent{code, false, modifierFlags()});
    }

    QList<quint16> pressing;
    for (const quint16 code : keys) {
        if (!heldKeys_.contains(code)) pressing.append(code);
    }
    for (const quint16 code : order(pressing, true)) {
        heldKeys_.insert(code);
        output.keys.append(KeyEvent{code, true, modifierFlags()});
    }

    QList<int> releasedButtons;
    for (const int button : heldMouseButtons_) {
        if (!mouseButtons.contains(button)) releasedButtons.append(button);
    }
    std::sort(releasedButtons.begin(), releasedButtons.end());
    for (const int button : releasedButtons) output.mouseButtons.append(MouseButtonEvent{button, false});

    QList<int> pressedButtons;
    for (const int button : mouseButtons) {
        if (!heldMouseButtons_.contains(button)) pressedButtons.append(button);
    }
    std::sort(pressedButtons.begin(), pressedButtons.end());
    for (const int button : pressedButtons) output.mouseButtons.append(MouseButtonEvent{button, true});

    heldMouseButtons_ = mouseButtons;
}

quint16 Engine::modifierFlags() const
{
    quint16 flags = 0;
    for (const quint16 code : heldKeys_) flags |= modifierFlag(code);
    return flags;
}

// MARK: Geometry

std::optional<int> Engine::radialItem(const Vector &value, int count)
{
    if (count <= 0 || value.length() < menuCentre) return std::nullopt;
    const double slice = 2 * pi / count;
    double angle = std::atan2(static_cast<double>(value.x), static_cast<double>(value.y));
    if (angle < 0) angle += 2 * pi;
    return static_cast<int>((angle + slice / 2) / slice) % count;
}

std::optional<int> Engine::gridItem(const Vector &value, int count)
{
    if (count <= 0) return std::nullopt;
    const int columns = gridColumns(count);
    const int rows = static_cast<int>(std::ceil(static_cast<double>(count) / columns));
    const int column = std::min(std::max(static_cast<int>((value.x + 1) / 2 * static_cast<float>(columns)), 0), columns - 1);
    const int row = std::min(std::max(static_cast<int>((1 - value.y) / 2 * static_cast<float>(rows)), 0), rows - 1);
    const int index = row * columns + column;
    if (index < count) return index;
    return std::nullopt;
}

int Engine::gridColumns(int count)
{
    return std::max(static_cast<int>(std::ceil(std::sqrt(static_cast<double>(count)))), 1);
}

} // namespace SteamInput
