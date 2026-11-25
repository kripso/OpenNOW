#pragma once

#include <QPointF>
#include <QString>
#include <QVariantMap>

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>

#include <SDL3/SDL_gamepad.h>

// Per-controller customisation: what the controls outside the Xbox-shaped wire layout (back
// paddles, extra buttons, gyro, trackpads) do while the stream owns the pad. ControllerInput owns
// the SDL state and the outputs; this header only parses a stored profile and does the math.
namespace ControllerMapping {

inline constexpr int minimumSensitivity = 10;
inline constexpr int maximumSensitivity = 500;
inline constexpr int defaultSensitivity = 100;
inline constexpr quint8 triggerActivationThreshold = 64;

struct ExtraButton {
    const char *name;
    SDL_GamepadButton button;
};

// Buttons SDL reports that the gamepad wire packet has no place for. The names are SDL's; on the
// Steam Controller paddle1..4 are R4, L4, R5, L5, misc1 is the quick access button, touchpad and
// misc2 are the left and right trackpad clicks, misc3/misc4 the left and right stick touch
// sensors, and misc5/misc6 the left and right grip sensors.
inline constexpr std::array<ExtraButton, 11> extraButtons{{
    {"paddle1", SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1},
    {"paddle2", SDL_GAMEPAD_BUTTON_LEFT_PADDLE1},
    {"paddle3", SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2},
    {"paddle4", SDL_GAMEPAD_BUTTON_LEFT_PADDLE2},
    {"misc1", SDL_GAMEPAD_BUTTON_MISC1},
    {"touchpad", SDL_GAMEPAD_BUTTON_TOUCHPAD},
    {"misc2", SDL_GAMEPAD_BUTTON_MISC2},
    {"misc3", SDL_GAMEPAD_BUTTON_MISC3},
    {"misc4", SDL_GAMEPAD_BUTTON_MISC4},
    {"misc5", SDL_GAMEPAD_BUTTON_MISC5},
    {"misc6", SDL_GAMEPAD_BUTTON_MISC6},
}};

// The first entries of extraButtons can be bound to an output; the rest are touch sensors that
// only make sense as a gyro activator.
inline constexpr std::size_t bindableButtons = 7;

[[nodiscard]] constexpr quint32 extraBit(int button)
{
    for (const auto &entry : extraButtons)
        if (entry.button == button) return 1u << static_cast<unsigned>(button);
    return 0;
}

struct Target {
    enum class Kind : quint8 { None, PadButton, LeftTrigger, RightTrigger, MouseButton, Key };
    Kind kind = Kind::None;
    quint16 code = 0; // PadButton: wire button mask. MouseButton: 1 left, 2 middle, 3 right. Key: virtual key.
    bool operator==(const Target &) const = default;
};

struct Activation {
    enum class Kind : quint8 { Always, ExtraButton, PadButton, LeftTrigger, RightTrigger, Touchpad };
    Kind kind = Kind::Always;
    quint32 code = 0; // ExtraButton: extraBit. PadButton: wire button mask. Touchpad: index.
    bool operator==(const Activation &) const = default;
};

enum class GyroMode : quint8 { Off, Mouse, RightStick };
enum class TouchpadMode : quint8 { Off, Mouse, LeftStick, RightStick };

struct Profile {
    std::array<Target, bindableButtons> bindings{};
    GyroMode gyro = GyroMode::Off;
    Activation gyroActivation{};
    int gyroSensitivity = defaultSensitivity;
    std::array<TouchpadMode, 2> touchpads{};
    std::array<int, 2> touchpadSensitivity{defaultSensitivity, defaultSensitivity};
    bool operator==(const Profile &) const = default;
};

[[nodiscard]] inline quint16 padButtonMask(QStringView name)
{
    struct Entry { QLatin1StringView name; quint16 mask; };
    static constexpr std::array<Entry, 14> entries{{
        {QLatin1StringView("a"), 0x1000}, {QLatin1StringView("b"), 0x2000},
        {QLatin1StringView("x"), 0x4000}, {QLatin1StringView("y"), 0x8000},
        {QLatin1StringView("lb"), 0x0100}, {QLatin1StringView("rb"), 0x0200},
        {QLatin1StringView("ls"), 0x0040}, {QLatin1StringView("rs"), 0x0080},
        {QLatin1StringView("back"), 0x0020}, {QLatin1StringView("start"), 0x0010},
        {QLatin1StringView("up"), 0x0001}, {QLatin1StringView("down"), 0x0002},
        {QLatin1StringView("left"), 0x0004}, {QLatin1StringView("right"), 0x0008},
    }};
    for (const auto &entry : entries)
        if (name == entry.name) return entry.mask;
    return 0;
}

[[nodiscard]] inline Target parseTarget(const QString &token)
{
    const auto separator = token.indexOf(QLatin1Char(':'));
    if (separator <= 0) return {};
    const auto kind = QStringView(token).left(separator);
    const auto value = QStringView(token).mid(separator + 1);
    if (kind == QLatin1StringView("pad")) {
        if (value == QLatin1StringView("lt")) return {Target::Kind::LeftTrigger, 0};
        if (value == QLatin1StringView("rt")) return {Target::Kind::RightTrigger, 0};
        if (const auto mask = padButtonMask(value)) return {Target::Kind::PadButton, mask};
    } else if (kind == QLatin1StringView("mouse")) {
        if (value == QLatin1StringView("left")) return {Target::Kind::MouseButton, 1};
        if (value == QLatin1StringView("middle")) return {Target::Kind::MouseButton, 2};
        if (value == QLatin1StringView("right")) return {Target::Kind::MouseButton, 3};
    } else if (kind == QLatin1StringView("key")) {
        bool ok = false;
        const auto virtualKey = value.toUInt(&ok);
        if (ok && virtualKey >= 1 && virtualKey <= 254) return {Target::Kind::Key, static_cast<quint16>(virtualKey)};
    }
    return {};
}

[[nodiscard]] inline Activation parseActivation(const QString &token)
{
    if (token == QLatin1StringView("lt")) return {Activation::Kind::LeftTrigger, 0};
    if (token == QLatin1StringView("rt")) return {Activation::Kind::RightTrigger, 0};
    if (token == QLatin1StringView("touch0")) return {Activation::Kind::Touchpad, 0};
    if (token == QLatin1StringView("touch1")) return {Activation::Kind::Touchpad, 1};
    if (token == QLatin1StringView("lb") || token == QLatin1StringView("rb"))
        return {Activation::Kind::PadButton, padButtonMask(token)};
    for (const auto &entry : extraButtons)
        if (token == QLatin1StringView(entry.name))
            return {Activation::Kind::ExtraButton, extraBit(entry.button)};
    return {};
}

[[nodiscard]] inline int sensitivity(const QVariantMap &profile, QLatin1StringView field)
{
    bool ok = false;
    const auto value = profile.value(field).toDouble(&ok);
    return ok && std::isfinite(value)
        ? std::clamp(static_cast<int>(value), minimumSensitivity, maximumSensitivity) : defaultSensitivity;
}

[[nodiscard]] inline QString bindingField(const ExtraButton &button)
{
    auto name = QString::fromLatin1(button.name);
    name[0] = name[0].toUpper();
    return QStringLiteral("bind") + name;
}

[[nodiscard]] inline Profile parse(const QVariantMap &profile)
{
    Profile result;
    for (std::size_t index = 0; index < bindableButtons; ++index)
        result.bindings[index] = parseTarget(profile.value(bindingField(extraButtons[index])).toString());
    const auto gyro = profile.value(QStringLiteral("gyroMode")).toString();
    result.gyro = gyro == QLatin1StringView("mouse") ? GyroMode::Mouse
        : gyro == QLatin1StringView("rightStick") ? GyroMode::RightStick : GyroMode::Off;
    result.gyroActivation = parseActivation(profile.value(QStringLiteral("gyroActivation")).toString());
    result.gyroSensitivity = sensitivity(profile, QLatin1StringView("gyroSensitivity"));
    const std::array<QLatin1StringView, 2> modes{QLatin1StringView("leftPadMode"), QLatin1StringView("rightPadMode")};
    const std::array<QLatin1StringView, 2> scales{QLatin1StringView("leftPadSensitivity"),
                                                  QLatin1StringView("rightPadSensitivity")};
    for (std::size_t pad = 0; pad < modes.size(); ++pad) {
        const auto mode = profile.value(modes[pad]).toString();
        result.touchpads[pad] = mode == QLatin1StringView("mouse") ? TouchpadMode::Mouse
            : mode == QLatin1StringView("leftStick") ? TouchpadMode::LeftStick
            : mode == QLatin1StringView("rightStick") ? TouchpadMode::RightStick : TouchpadMode::Off;
        result.touchpadSensitivity[pad] = sensitivity(profile, scales[pad]);
    }
    return result;
}

// SDL reports gamepad gyro in radians per second: x is pitch (positive tilts the top of the pad
// toward the player) and y is yaw (positive turns the pad to the left). Both map to a negative
// screen direction, so turning left looks left and tilting back looks up.
inline constexpr double gyroMouseCountsPerDegree = 20.0;
inline constexpr double gyroStickFullScaleDegreesPerSecond = 180.0;
inline constexpr double gyroSoftThresholdDegreesPerSecond = 1.0;
inline constexpr double gyroMaximumStepSeconds = 0.05;
inline constexpr double touchpadMouseCountsPerSwipe = 1200.0;
inline constexpr double touchpadStickReach = 1.25;

// Degrees per second on the screen axes, with resting noise faded out below the soft threshold.
[[nodiscard]] inline QPointF gyroScreenRate(float pitch, float yaw)
{
    const auto degrees = 180.0 / std::numbers::pi;
    const auto x = -static_cast<double>(yaw) * degrees;
    const auto y = -static_cast<double>(pitch) * degrees;
    const auto magnitude = std::hypot(x, y);
    if (!std::isfinite(magnitude) || magnitude == 0.0) return {};
    const auto scale = std::min(1.0, magnitude / gyroSoftThresholdDegreesPerSecond);
    return {x * scale, y * scale};
}

[[nodiscard]] inline QPointF gyroMouseCounts(float pitch, float yaw, double seconds, int sensitivity)
{
    const auto step = std::clamp(seconds, 0.0, gyroMaximumStepSeconds);
    return gyroScreenRate(pitch, yaw) * (step * gyroMouseCountsPerDegree * sensitivity / 100.0);
}

// A stick deflection in [-1, 1] on SDL's axes (y grows downward), limited to the unit circle.
[[nodiscard]] inline QPointF unitStick(QPointF value)
{
    const auto magnitude = std::hypot(value.x(), value.y());
    if (!std::isfinite(magnitude)) return {};
    return magnitude > 1.0 ? value / magnitude : value;
}

[[nodiscard]] inline QPointF gyroStick(float pitch, float yaw, int sensitivity)
{
    return unitStick(gyroScreenRate(pitch, yaw) * (sensitivity / 100.0 / gyroStickFullScaleDegreesPerSecond));
}

[[nodiscard]] inline QPointF touchpadMouseCounts(QPointF from, QPointF to, int sensitivity)
{
    return (to - from) * (touchpadMouseCountsPerSwipe * sensitivity / 100.0);
}

[[nodiscard]] inline QPointF touchpadStick(QPointF position, int sensitivity)
{
    return unitStick((position - QPointF(0.5, 0.5)) * (2.0 * touchpadStickReach * sensitivity / 100.0));
}

// Adds a mapped deflection to a physical stick value and returns the wire range.
[[nodiscard]] inline QPair<qint16, qint16> combineStick(QPair<qint16, qint16> physical, QPointF mapped)
{
    const auto combined = unitStick(QPointF(physical.first / 32767.0, physical.second / 32767.0) + mapped);
    return {static_cast<qint16>(std::lround(combined.x() * 32767.0)),
            static_cast<qint16>(std::lround(combined.y() * 32767.0))};
}

}
