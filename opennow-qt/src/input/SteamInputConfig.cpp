#include "input/SteamInputConfig.h"

#include <QLocale>
#include <QStringList>

#include <algorithm>
#include <climits>
#include <cmath>
#include <limits>
#include <utility>

namespace SteamInput {

std::optional<long long> parseInteger(const QString &text)
{
    if (text.isEmpty()) return std::nullopt;
    qsizetype index = 0;
    bool negative = false;
    if (text[0] == u'+' || text[0] == u'-') {
        negative = text[0] == u'-';
        index = 1;
    }
    if (index == text.size()) return std::nullopt;
    long long value = 0;
    for (; index < text.size(); ++index) {
        const char16_t c = text[index].unicode();
        if (c < u'0' || c > u'9') return std::nullopt;
        const long long digit = c - u'0';
        if (value > (std::numeric_limits<long long>::max() - digit) / 10) return std::nullopt;
        value = value * 10 + digit;
    }
    return negative ? -value : value;
}

namespace {

// Splits on at most maxSplits separators; empty pieces are dropped when omitEmpty is set.
QStringList splitSwift(const QString &text, QChar separator, int maxSplits, bool omitEmpty)
{
    QStringList pieces;
    qsizetype start = 0;
    for (int splits = 0; splits < maxSplits; ++splits) {
        const qsizetype at = text.indexOf(separator, start);
        if (at < 0) break;
        pieces.append(text.mid(start, at - start));
        start = at + 1;
    }
    pieces.append(text.mid(start));
    if (omitEmpty) pieces.removeAll(QString());
    return pieces;
}

std::optional<int> parseIntValue(const std::optional<QString> &text)
{
    if (!text) return std::nullopt;
    const auto parsed = parseInteger(*text);
    if (!parsed || *parsed < std::numeric_limits<int>::min() || *parsed > std::numeric_limits<int>::max()) {
        return std::nullopt;
    }
    return static_cast<int>(*parsed);
}

// An optional plus sign and then decimal digits.
std::optional<quint64> parseUnsigned64(const QString &text)
{
    if (text.isEmpty()) return std::nullopt;
    qsizetype index = text[0] == u'+' ? 1 : 0;
    if (index == text.size()) return std::nullopt;
    quint64 value = 0;
    for (; index < text.size(); ++index) {
        const char16_t c = text[index].unicode();
        if (c < u'0' || c > u'9') return std::nullopt;
        const quint64 digit = c - u'0';
        if (value > (std::numeric_limits<quint64>::max() - digit) / 10) return std::nullopt;
        value = value * 10 + digit;
    }
    return value;
}

// The whole text must be a number, with no surrounding spaces.
std::optional<double> parseDouble(const QString &text)
{
    if (text.isEmpty() || text.front().isSpace() || text.back().isSpace()) return std::nullopt;
    bool ok = false;
    const double value = text.toDouble(&ok);
    if (!ok) return std::nullopt;
    return value;
}

QString joinSorted(const std::set<QString> &items)
{
    QStringList list(items.begin(), items.end());
    return list.join(QStringLiteral(", "));
}

// Words the importer reports back to the player, kept in one place so the wording is the same
// whichever section of a layout they came from.
struct ImportNotes {
    int gameActions = 0;
    std::set<QString> unknownBindings;
    std::set<QString> unsupportedModes;
    std::set<QString> unsupportedSources;
    std::set<QString> unsupportedActivators;
    std::set<QString> gyroButtons;
    std::set<QString> approximatedModes;

    QStringList sentences() const
    {
        QStringList result;
        if (gameActions > 0) {
            result.append(QStringLiteral("Some controls (%1) are bound to the game's own Steam Input actions. They are sent as the matching gamepad button so the game's own layout on the host handles them; those with no gamepad equivalent do nothing.").arg(gameActions));
        }
        if (!unsupportedModes.empty()) {
            result.append(QStringLiteral("Not supported yet, so these do nothing: %1.").arg(joinSorted(unsupportedModes)));
        }
        if (!approximatedModes.empty()) {
            result.append(QStringLiteral("Approximated: %1.").arg(joinSorted(approximatedModes)));
        }
        if (!unsupportedActivators.empty()) {
            result.append(QStringLiteral("Ignored press types: %1.").arg(joinSorted(unsupportedActivators)));
        }
        if (!unknownBindings.empty()) {
            result.append(QStringLiteral("Ignored Steam-only actions: %1.").arg(joinSorted(unknownBindings)));
        }
        if (!unsupportedSources.empty()) {
            result.append(QStringLiteral("This controller has no %1.").arg(joinSorted(unsupportedSources)));
        }
        if (!gyroButtons.empty()) {
            result.append(QStringLiteral("Part of the gyro's enable button setting could not be read (%1).").arg(joinSorted(gyroButtons)));
        }
        return result;
    }
};

QString localized(const QString &text, const Vdf::Value &root)
{
    if (!text.startsWith(u'#')) return text;
    const QString key = text.mid(1);
    const Vdf::Value *localization = root.child(QStringLiteral("localization"));
    const Vdf::Value *english = localization ? localization->child(QStringLiteral("english")) : nullptr;
    if (english) {
        if (const auto value = Vdf::stringOf(english->child(key))) return *value;
    }
    return key;
}

// The buttons in a gyro button set, by bit. They follow the first Steam Controller's button
// report, with the triggers' soft pulls added above it.
std::optional<Config::InputRef> gyroMaskButton(int bit)
{
    using Ref = Config::InputRef;
    using Source = Config::Source;
    switch (bit) {
    case 0: return Ref{Source::RightTrigger, QStringLiteral("click")};
    case 1: return Ref{Source::LeftTrigger, QStringLiteral("click")};
    case 2: return Ref{Source::Switches, QStringLiteral("right_bumper")};
    case 3: return Ref{Source::Switches, QStringLiteral("left_bumper")};
    case 4: return Ref{Source::ButtonDiamond, QStringLiteral("button_y")};
    case 5: return Ref{Source::ButtonDiamond, QStringLiteral("button_b")};
    case 6: return Ref{Source::ButtonDiamond, QStringLiteral("button_x")};
    case 7: return Ref{Source::ButtonDiamond, QStringLiteral("button_a")};
    case 8: return Ref{Source::Dpad, QStringLiteral("dpad_north")};
    case 9: return Ref{Source::Dpad, QStringLiteral("dpad_east")};
    case 10: return Ref{Source::Dpad, QStringLiteral("dpad_west")};
    case 11: return Ref{Source::Dpad, QStringLiteral("dpad_south")};
    case 12: return Ref{Source::Switches, QStringLiteral("button_menu")};
    case 14: return Ref{Source::Switches, QStringLiteral("button_escape")};
    case 15: return Ref{Source::Switches, QStringLiteral("button_back_left")};
    case 16: return Ref{Source::Switches, QStringLiteral("button_back_right")};
    case 17: return Ref{Source::LeftTrackpad, QStringLiteral("click")};
    case 18: return Ref{Source::RightTrackpad, QStringLiteral("click")};
    case 19: return Ref{Source::LeftTrackpad, QStringLiteral("touch")};
    case 20: return Ref{Source::RightTrackpad, QStringLiteral("touch")};
    case 22: return Ref{Source::Joystick, QStringLiteral("click")};
    case 24: return Ref{Source::RightTrigger, QStringLiteral("edge")};
    case 25: return Ref{Source::LeftTrigger, QStringLiteral("edge")};
    default: return std::nullopt;
    }
}

// Steam stores the gyro's enable button as a number from the list its configurator shows.
std::optional<Config::InputRef> gyroButton(int code)
{
    using Ref = Config::InputRef;
    using Source = Config::Source;
    switch (code) {
    case 1: return Ref{Source::RightTrackpad, QStringLiteral("touch")};
    case 2: return Ref{Source::LeftTrackpad, QStringLiteral("touch")};
    case 3: return Ref{Source::RightTrackpad, QStringLiteral("click")};
    case 4: return Ref{Source::LeftTrackpad, QStringLiteral("click")};
    case 5: return Ref{Source::Switches, QStringLiteral("right_bumper")};
    case 6: return Ref{Source::Switches, QStringLiteral("left_bumper")};
    case 7: return Ref{Source::Switches, QStringLiteral("button_back_right")};
    case 8: return Ref{Source::Switches, QStringLiteral("button_back_left")};
    case 9: return Ref{Source::RightTrigger, QStringLiteral("click")};
    case 10: return Ref{Source::LeftTrigger, QStringLiteral("click")};
    case 11: return Ref{Source::RightTrigger, QStringLiteral("edge")};
    case 12: return Ref{Source::LeftTrigger, QStringLiteral("edge")};
    case 13: return Ref{Source::ButtonDiamond, QStringLiteral("button_a")};
    case 14: return Ref{Source::ButtonDiamond, QStringLiteral("button_b")};
    case 15: return Ref{Source::ButtonDiamond, QStringLiteral("button_x")};
    case 16: return Ref{Source::ButtonDiamond, QStringLiteral("button_y")};
    case 17: return Ref{Source::Joystick, QStringLiteral("click")};
    default: return std::nullopt;
    }
}

} // namespace

std::optional<Config::Mode> modeFromToken(const QString &token)
{
    using Mode = Config::Mode;
    static const std::map<QString, Mode> modes{
        {QStringLiteral("four_buttons"), Mode::FourButtons},
        {QStringLiteral("switches"), Mode::Switches},
        {QStringLiteral("dpad"), Mode::Dpad},
        {QStringLiteral("single_button"), Mode::SingleButton},
        {QStringLiteral("trigger"), Mode::Trigger},
        {QStringLiteral("joystick_move"), Mode::JoystickMove},
        {QStringLiteral("joystick_camera"), Mode::JoystickCamera},
        {QStringLiteral("joystick_mouse"), Mode::JoystickMouse},
        {QStringLiteral("absolute_mouse"), Mode::AbsoluteMouse},
        {QStringLiteral("mouse_joystick"), Mode::MouseJoystick},
        {QStringLiteral("scrollwheel"), Mode::ScrollWheel},
        {QStringLiteral("opennow_scroll"), Mode::LinearScroll},
        {QStringLiteral("gyro_to_mouse"), Mode::GyroToMouse},
        {QStringLiteral("gyro_to_joystick"), Mode::GyroToJoystick},
        {QStringLiteral("flickstick"), Mode::FlickStick},
        {QStringLiteral("mouse_region"), Mode::MouseRegion},
        {QStringLiteral("2dscroll"), Mode::Scroll2D},
        {QStringLiteral("radial_menu"), Mode::RadialMenu},
        {QStringLiteral("touch_menu"), Mode::TouchMenu},
        {QStringLiteral("disabled"), Mode::Disabled},
    };
    const auto found = modes.find(token);
    if (found == modes.end()) return std::nullopt;
    return found->second;
}

namespace {

// Steam's key names, as Windows virtual-key codes.
std::optional<quint16> virtualKeyCode(const QString &name)
{
    static const std::map<QString, quint16> keys = [] {
        std::map<QString, quint16> table{
            {QStringLiteral("SPACE"), 0x20}, {QStringLiteral("RETURN"), 0x0d}, {QStringLiteral("ENTER"), 0x0d},
            {QStringLiteral("ESCAPE"), 0x1b}, {QStringLiteral("TAB"), 0x09}, {QStringLiteral("BACKSPACE"), 0x08},
            {QStringLiteral("LEFT_SHIFT"), 0xa0}, {QStringLiteral("RIGHT_SHIFT"), 0xa1},
            {QStringLiteral("LEFT_CONTROL"), 0xa2}, {QStringLiteral("RIGHT_CONTROL"), 0xa3},
            {QStringLiteral("LEFT_ALT"), 0xa4}, {QStringLiteral("RIGHT_ALT"), 0xa5},
            {QStringLiteral("LEFT_WINDOWS"), 0x5b}, {QStringLiteral("RIGHT_WINDOWS"), 0x5c},
            {QStringLiteral("UP_ARROW"), 0x26}, {QStringLiteral("DOWN_ARROW"), 0x28},
            {QStringLiteral("LEFT_ARROW"), 0x25}, {QStringLiteral("RIGHT_ARROW"), 0x27},
            {QStringLiteral("HOME"), 0x24}, {QStringLiteral("END"), 0x23},
            {QStringLiteral("PAGE_UP"), 0x21}, {QStringLiteral("PAGE_DOWN"), 0x22},
            {QStringLiteral("INSERT"), 0x2d}, {QStringLiteral("DELETE"), 0x2e},
            {QStringLiteral("CAPSLOCK"), 0x14}, {QStringLiteral("NUM_LOCK"), 0x90},
            {QStringLiteral("SCROLL_LOCK"), 0x91}, {QStringLiteral("PRINT_SCREEN"), 0x2c},
            {QStringLiteral("BREAK"), 0x13}, {QStringLiteral("PAUSE"), 0x13},
            {QStringLiteral("VOLUME_MUTE"), 0xad}, {QStringLiteral("VOLUME_DOWN"), 0xae},
            {QStringLiteral("VOLUME_UP"), 0xaf}, {QStringLiteral("BACK_TICK"), 0xc0},
            {QStringLiteral("DASH"), 0xbd}, {QStringLiteral("EQUALS"), 0xbb},
            {QStringLiteral("LEFT_BRACKET"), 0xdb}, {QStringLiteral("RIGHT_BRACKET"), 0xdd},
            {QStringLiteral("BACKSLASH"), 0xdc}, {QStringLiteral("SEMICOLON"), 0xba},
            {QStringLiteral("SINGLE_QUOTE"), 0xde}, {QStringLiteral("COMMA"), 0xbc},
            {QStringLiteral("PERIOD"), 0xbe}, {QStringLiteral("FORWARD_SLASH"), 0xbf},
            {QStringLiteral("KEYPAD_FORWARD_SLASH"), 0x6f}, {QStringLiteral("KEYPAD_ASTERISK"), 0x6a},
            {QStringLiteral("KEYPAD_DASH"), 0x6d}, {QStringLiteral("KEYPAD_PLUS"), 0x6b},
            {QStringLiteral("KEYPAD_ENTER"), 0x0d}, {QStringLiteral("KEYPAD_PERIOD"), 0x6e},
        };
        for (int code = 0x41; code <= 0x5a; ++code) {
            table[QString(QChar(static_cast<char16_t>(code)))] = static_cast<quint16>(code);
        }
        for (int digit = 0; digit <= 9; ++digit) {
            table[QString::number(digit)] = static_cast<quint16>(0x30 + digit);
            table[QStringLiteral("KEYPAD_%1").arg(digit)] = static_cast<quint16>(0x60 + digit);
        }
        for (int number = 1; number <= 12; ++number) {
            table[QStringLiteral("F%1").arg(number)] = static_cast<quint16>(0x6f + number);
        }
        return table;
    }();
    const auto found = keys.find(name);
    if (found == keys.end()) return std::nullopt;
    return found->second;
}

std::optional<PadButton> padButtonForSteamName(const QString &name)
{
    static const std::map<QString, PadButton> buttons{
        {QStringLiteral("A"), PadButton::A}, {QStringLiteral("B"), PadButton::B},
        {QStringLiteral("X"), PadButton::X}, {QStringLiteral("Y"), PadButton::Y},
        {QStringLiteral("SHOULDER_LEFT"), PadButton::Lb}, {QStringLiteral("SHOULDER_RIGHT"), PadButton::Rb},
        {QStringLiteral("TRIGGER_LEFT"), PadButton::Lt}, {QStringLiteral("TRIGGER_RIGHT"), PadButton::Rt},
        {QStringLiteral("JOYSTICK_LEFT"), PadButton::Ls}, {QStringLiteral("JOYSTICK_RIGHT"), PadButton::Rs},
        {QStringLiteral("SELECT"), PadButton::Back}, {QStringLiteral("START"), PadButton::Start},
        {QStringLiteral("GUIDE"), PadButton::Guide},
        {QStringLiteral("DPAD_UP"), PadButton::Up}, {QStringLiteral("DPAD_DOWN"), PadButton::Down},
        {QStringLiteral("DPAD_LEFT"), PadButton::Left}, {QStringLiteral("DPAD_RIGHT"), PadButton::Right},
    };
    const auto found = buttons.find(name);
    if (found == buttons.end()) return std::nullopt;
    return found->second;
}

std::optional<Config::Binding> parseBinding(const QString &text, ImportNotes &notes)
{
    using Binding = Config::Binding;
    const QStringList words = splitSwift(text, u' ', INT_MAX, true);
    if (words.isEmpty()) return std::nullopt;
    const QString verb = words.first().toLower();
    const QString argument = words.size() > 1 ? words[1].toUpper() : QString();

    if (verb == QStringLiteral("key_press")) {
        if (const auto code = virtualKeyCode(argument)) return Binding::key(*code);
        notes.unknownBindings.insert(QStringLiteral("key ") + argument);
    } else if (verb == QStringLiteral("mouse_button")) {
        if (argument == QStringLiteral("LEFT")) return Binding::mouseButton(1);
        if (argument == QStringLiteral("MIDDLE")) return Binding::mouseButton(2);
        if (argument == QStringLiteral("RIGHT")) return Binding::mouseButton(3);
        if (argument == QStringLiteral("BACK")) return Binding::mouseButton(4);
        if (argument == QStringLiteral("FORWARD")) return Binding::mouseButton(5);
        notes.unknownBindings.insert(QStringLiteral("mouse button ") + argument);
    } else if (verb == QStringLiteral("mouse_wheel")) {
        if (argument == QStringLiteral("SCROLL_UP")) return Binding::wheel(1);
        if (argument == QStringLiteral("SCROLL_DOWN")) return Binding::wheel(-1);
    } else if (verb == QStringLiteral("xinput_button")) {
        if (const auto button = padButtonForSteamName(argument)) return Binding::pad(*button);
        notes.unknownBindings.insert(QStringLiteral("gamepad ") + argument);
    } else if (verb == QStringLiteral("mode_shift")) {
        if (words.size() > 2) {
            const auto source = sourceFromToken(words[1].toLower());
            const auto group = parseIntValue(words[2]);
            if (source && group) return Binding::modeShift(*source, *group);
        }
    } else if (verb == QStringLiteral("game_action")) {
        notes.gameActions += 1;
    } else if (verb == QStringLiteral("controller_action")) {
        // Sets and layers are numbered from one in bindings and from zero in the file.
        std::optional<int> target;
        if (words.size() > 2) {
            if (const auto number = parseIntValue(words[2])) target = *number - 1;
        }
        if (argument == QStringLiteral("CHANGE_PRESET")) {
            if (target) return Binding::changeSet(*target);
        } else if (argument == QStringLiteral("HOLD_LAYER")) {
            if (target) return Binding::holdLayer(*target);
        } else if (argument == QStringLiteral("ADD_LAYER")) {
            if (target) return Binding::addLayer(*target);
        } else if (argument == QStringLiteral("REMOVE_LAYER")) {
            if (target) return Binding::removeLayer(*target);
        } else if (argument == QStringLiteral("EMPTY_BINDING") || argument == QStringLiteral("EMPTY_SUB_COMMAND")
                   || argument.isEmpty()) {
            // Nothing to send.
        } else {
            notes.unknownBindings.insert(words[1].toLower());
        }
    } else {
        notes.unknownBindings.insert(verb);
    }
    return std::nullopt;
}

std::optional<Config::Activator> parseActivator(const QString &name, const Vdf::Value &raw, ImportNotes &notes)
{
    using Activator = Config::Activator;
    Activator activator;
    const QString lowered = name.toLower();
    if (lowered == QStringLiteral("full_press")) {
        activator.kind = Activator::Kind::FullPress;
    } else if (lowered == QStringLiteral("soft_press")) {
        activator.kind = Activator::Kind::SoftPress;
    } else if (lowered == QStringLiteral("long_press")) {
        activator.kind = Activator::Kind::LongPress;
    } else if (lowered == QStringLiteral("double_press")) {
        activator.kind = Activator::Kind::DoublePress;
    } else if (lowered == QStringLiteral("start_press")) {
        activator.kind = Activator::Kind::StartPress;
    } else if (lowered == QStringLiteral("release")) {
        activator.kind = Activator::Kind::Release;
    } else {
        notes.unsupportedActivators.insert(name);
        return std::nullopt;
    }

    if (const Vdf::Value *bindings = raw.child(QStringLiteral("bindings"))) {
        for (const Vdf::Value *binding : bindings->all(QStringLiteral("binding"))) {
            const auto text = Vdf::stringOf(binding);
            if (!text) continue;
            QStringList fields = text->split(u',', Qt::KeepEmptyParts);
            for (QString &field : fields) field = field.trimmed();
            if (activator.label.isEmpty() && fields.size() > 1 && !fields[1].isEmpty()) {
                activator.label = fields[1];
            }
            const QString first = fields.first();
            if (first.toLower().startsWith(QStringLiteral("game_action"))) activator.nativeAction = true;
            if (const auto parsed = parseBinding(first, notes)) activator.bindings.append(*parsed);
        }
    }

    const Vdf::Value *settings = raw.child(QStringLiteral("settings"));
    const auto setting = [settings](const char *key) -> std::optional<double> {
        const Vdf::Value *value = settings ? settings->child(QString::fromLatin1(key)) : nullptr;
        const auto text = Vdf::stringOf(value);
        if (!text) return std::nullopt;
        return parseDouble(*text);
    };
    activator.toggle = setting("toggle") == 1.0;
    activator.holdRepeats = setting("hold_repeats") == 1.0;
    // Steam's repeat rate runs from slow to fast on an undocumented scale; this spreads it
    // between two and twenty presses a second.
    if (const auto rate = setting("repeat_rate")) {
        activator.repeatInterval = 1 / (2 + std::min(std::max(*rate, 0.0), 100.0) * 0.18);
    }
    if (const auto time = setting("long_press_time")) activator.longPressTime = std::max(*time, 0.0) / 1000;
    if (const auto time = setting("doubetap_max_duration")) activator.doubleTapTime = std::max(*time, 0.0) / 1000;
    if (const auto time = setting("delay_start")) activator.delayStart = std::max(*time, 0.0) / 1000;
    if (const auto time = setting("delay_end")) activator.delayEnd = std::max(*time, 0.0) / 1000;
    return activator;
}

Config::Group makeGroup(int id, const Vdf::Value &raw, ImportNotes &notes)
{
    using Mode = Config::Mode;
    const QString modeName = Vdf::stringOf(raw.child(QStringLiteral("mode"))).value_or(QString());
    std::optional<Mode> mode = modeFromToken(modeName);
    if (mode == Mode::LinearScroll) mode = std::nullopt;
    if (modeName == QStringLiteral("gyro_to_camera_angles")) {
        mode = Mode::GyroToMouse;
    } else if (modeName == QStringLiteral("gyro_to_joystick_deflection")) {
        mode = Mode::GyroToJoystick;
        notes.approximatedModes.insert(QStringLiteral("gyro tilt as a stick (follows turning speed instead)"));
    }
    if (!mode && !modeName.isEmpty() && modeName != QStringLiteral("reference")) {
        notes.unsupportedModes.insert(modeName);
    }
    if (modeName == QStringLiteral("mouse_joystick")) notes.approximatedModes.insert(QStringLiteral("mouse-like joystick"));

    Config::Group group;
    group.id = id;
    group.mode = mode.value_or(Mode::Disabled);
    group.name = Vdf::stringOf(raw.child(QStringLiteral("name"))).value_or(QString());

    if (const Vdf::Value *settings = raw.child(QStringLiteral("settings"))) {
        for (const Vdf::Entry &setting : settings->entries()) {
            const auto text = Vdf::stringOf(&setting.value);
            if (!text) continue;
            if (const auto number = parseDouble(*text)) {
                group.settings[setting.key.toLower()] = *number;
            } else if (*text == QStringLiteral("true") || *text == QStringLiteral("false")) {
                group.settings[setting.key.toLower()] = *text == QStringLiteral("true") ? 1 : 0;
            }
        }
    }

    if (const Vdf::Value *inputs = raw.child(QStringLiteral("inputs"))) {
        for (const Vdf::Entry &input : inputs->entries()) {
            QList<Config::Activator> activators;
            if (const Vdf::Value *list = input.value.child(QStringLiteral("activators"))) {
                for (const Vdf::Entry &entry : list->entries()) {
                    // The same press type may be listed more than once, each with its own bindings.
                    if (const auto activator = parseActivator(entry.key, entry.value, notes)) {
                        activators.append(*activator);
                    }
                }
            }
            group.inputs[input.key.toLower()] = activators;
        }
    }

    if (const Vdf::Value *gameActions = raw.child(QStringLiteral("gameactions"))) {
        if (!gameActions->entries().empty()) group.settings[QStringLiteral("opennow_native_actions")] = 1;
    }

    // Newer files name the gyro's buttons as a set of bits; older ones as one number.
    quint64 mask = 0;
    if (const Vdf::Value *settings = raw.child(QStringLiteral("settings"))) {
        const auto text = Vdf::stringOf(settings->child(QStringLiteral("gyro_ratchet_button_mask")));
        if (text) mask = parseUnsigned64(*text).value_or(0);
    }
    if (mask != 0) {
        for (int bit = 0; bit < 64; ++bit) {
            if ((mask & (quint64(1) << bit)) == 0) continue;
            if (const auto button = gyroMaskButton(bit)) {
                group.gyroActivators.append(*button);
            } else {
                notes.gyroButtons.insert(QStringLiteral("button %1").arg(bit));
            }
        }
    } else if (const auto code = group.settings.find(QStringLiteral("gyro_button"));
               code != group.settings.end() && code->second != 0 && std::abs(code->second) < 1'000) {
        const int number = static_cast<int>(code->second);
        if (const auto button = gyroButton(number)) {
            group.gyroActivators = {*button};
        } else {
            notes.gyroButtons.insert(QStringLiteral("code %1").arg(number));
        }
    }

    if (const auto invert = group.settings.find(QStringLiteral("gyro_button_invert")); invert != group.settings.end()) {
        if (invert->second == 1.0) group.gyroActivation = Config::GyroActivation::WhileReleased;
        if (invert->second == 2.0) group.gyroActivation = Config::GyroActivation::Toggle;
    }
    return group;
}

// A control bound to a native action is sent as the gamepad control of the same name, where there
// is one.
std::optional<PadButton> gamepadEquivalent(Config::Source source, const QString &input)
{
    using Source = Config::Source;
    if (source == Source::ButtonDiamond) {
        if (input == QStringLiteral("button_a")) return PadButton::A;
        if (input == QStringLiteral("button_b")) return PadButton::B;
        if (input == QStringLiteral("button_x")) return PadButton::X;
        if (input == QStringLiteral("button_y")) return PadButton::Y;
    } else if (source == Source::Dpad) {
        if (input == QStringLiteral("dpad_north")) return PadButton::Up;
        if (input == QStringLiteral("dpad_south")) return PadButton::Down;
        if (input == QStringLiteral("dpad_west")) return PadButton::Left;
        if (input == QStringLiteral("dpad_east")) return PadButton::Right;
    } else if (source == Source::Switches) {
        if (input == QStringLiteral("left_bumper")) return PadButton::Lb;
        if (input == QStringLiteral("right_bumper")) return PadButton::Rb;
        if (input == QStringLiteral("button_escape")) return PadButton::Start;
        if (input == QStringLiteral("button_menu")) return PadButton::Back;
    } else if (source == Source::Joystick) {
        if (input == QStringLiteral("click")) return PadButton::Ls;
    } else if (source == Source::RightJoystick) {
        if (input == QStringLiteral("click")) return PadButton::Rs;
    }
    return std::nullopt;
}

void sendNativeActionsAsGamepad(Config &config)
{
    for (const auto &[unusedKey, set] : config.sets) {
        for (const auto &[source, id] : set.groups) {
            const auto found = config.groups.find(id);
            if (found == config.groups.end()) continue;
            Config::Group group = found->second;
            bool native = group.settings.count(QStringLiteral("opennow_native_actions")) != 0
                          && group.settings[QStringLiteral("opennow_native_actions")] == 1.0;
            for (auto &[input, activators] : group.inputs) {
                for (qsizetype index = 0; index < activators.size(); ++index) {
                    auto &activator = activators[index];
                    if (!activator.nativeAction || !activator.bindings.isEmpty()) continue;
                    native = true;
                    if (const auto button = gamepadEquivalent(source, input)) {
                        activator.bindings = {Config::Binding::pad(*button)};
                    }
                }
            }
            if (native && group.mode == Config::Mode::Trigger && group.settings.count(QStringLiteral("output_trigger")) == 0) {
                if (source == Config::Source::LeftTrigger) group.settings[QStringLiteral("output_trigger")] = 1;
                if (source == Config::Source::RightTrigger) group.settings[QStringLiteral("output_trigger")] = 2;
            }
            config.groups[id] = group;
        }
    }
}

int nextGroupID(const Config &config)
{
    return config.groups.empty() ? 1 : config.groups.rbegin()->first + 1;
}

// Gives every set the Steam button, which Steam reserves and its layouts therefore never bind.
void addSystemDefaults(Config &config)
{
    const int id = nextGroupID(config);
    Config::Group group;
    group.id = id;
    group.mode = Config::Mode::Switches;
    Config::Activator steam;
    steam.bindings = {Config::Binding::shortcut(Shortcut::Controls)};
    group.inputs[QStringLiteral("steam")] = {steam};
    config.groups[id] = group;
    for (auto &[unusedKey, set] : config.sets) {
        if (!set.isLayer) set.groups[Config::Source::System] = id;
    }
}

} // namespace

// MARK: Valve's text format

namespace Vdf {

Value Value::makeString(QString text)
{
    Value value;
    value.object_ = false;
    value.text_ = std::move(text);
    return value;
}

Value Value::makeObject(std::vector<Entry> entries)
{
    Value value;
    value.object_ = true;
    value.entries_ = std::move(entries);
    return value;
}

std::optional<QString> Value::string() const
{
    if (object_) return std::nullopt;
    return text_;
}

const std::vector<Entry> &Value::entries() const
{
    static const std::vector<Entry> none;
    return object_ ? entries_ : none;
}

const Value *Value::child(const QString &key) const
{
    for (const Entry &entry : entries()) {
        if (entry.key.compare(key, Qt::CaseInsensitive) == 0) return &entry.value;
    }
    return nullptr;
}

std::vector<const Value *> Value::all(const QString &key) const
{
    std::vector<const Value *> matches;
    for (const Entry &entry : entries()) {
        if (entry.key.compare(key, Qt::CaseInsensitive) == 0) matches.push_back(&entry.value);
    }
    return matches;
}

std::optional<QString> stringOf(const Value *value)
{
    if (!value) return std::nullopt;
    return value->string();
}

namespace {

class Scanner {
public:
    explicit Scanner(const QString &text) : chars_(text) {}

    // Entries until the end of the text, or until the closing brace when untilClose is set.
    std::optional<std::vector<Entry>> entries(int depth, bool untilClose)
    {
        if (depth > maximumDepth) return std::nullopt;
        std::vector<Entry> result;
        while (const auto token = next()) {
            switch (token->kind) {
            case Token::Kind::Close:
                if (untilClose) return result;
                return std::nullopt;
            case Token::Kind::Open:
                return std::nullopt;
            case Token::Kind::String: {
                const auto value = next();
                if (!value) return std::nullopt;
                switch (value->kind) {
                case Token::Kind::String:
                    result.push_back(Entry{token->text, Value::makeString(value->text)});
                    break;
                case Token::Kind::Open: {
                    auto children = entries(depth + 1, true);
                    if (!children) return std::nullopt;
                    result.push_back(Entry{token->text, Value::makeObject(std::move(*children))});
                    break;
                }
                case Token::Kind::Close:
                    return std::nullopt;
                }
                break;
            }
            }
        }
        if (untilClose) return std::nullopt;
        return result;
    }

private:
    static constexpr int maximumDepth = 32;

    struct Token {
        enum class Kind { Open, Close, String };
        Kind kind = Kind::String;
        QString text;
    };

    std::optional<Token> next()
    {
        while (index_ < chars_.size()) {
            const QChar current = chars_[index_];
            if (current.isSpace() || current.unicode() == 0xfeff) {
                ++index_;
            } else if (current == u'/' && index_ + 1 < chars_.size() && chars_[index_ + 1] == u'/') {
                while (index_ < chars_.size() && chars_[index_] != u'\n') ++index_;
            } else {
                break;
            }
        }
        if (index_ >= chars_.size()) return std::nullopt;

        const QChar scalar = chars_[index_];
        if (scalar == u'{') {
            ++index_;
            return Token{Token::Kind::Open, {}};
        }
        if (scalar == u'}') {
            ++index_;
            return Token{Token::Kind::Close, {}};
        }
        QString text;
        if (scalar == u'"') {
            ++index_;
            while (index_ < chars_.size() && chars_[index_] != u'"') {
                // A backslash takes the next character literally.
                if (chars_[index_] == u'\\' && index_ + 1 < chars_.size()) ++index_;
                text.append(chars_[index_]);
                ++index_;
            }
            ++index_;
        } else {
            while (index_ < chars_.size()) {
                const QChar current = chars_[index_];
                if (current.isSpace() || current == u'{' || current == u'}' || current == u'"') break;
                text.append(current);
                ++index_;
            }
        }
        return Token{Token::Kind::String, std::move(text)};
    }

    QString chars_;
    qsizetype index_ = 0;
};

} // namespace

std::optional<Value> parse(const QString &text)
{
    Scanner scanner(text);
    auto entries = scanner.entries(0, false);
    if (!entries) return std::nullopt;
    return Value::makeObject(std::move(*entries));
}

} // namespace Vdf

// MARK: Pad and shortcut names

quint16 padButtonMask(PadButton button)
{
    switch (button) {
    case PadButton::A: return 0x1000;
    case PadButton::B: return 0x2000;
    case PadButton::X: return 0x4000;
    case PadButton::Y: return 0x8000;
    case PadButton::Lb: return 0x0100;
    case PadButton::Rb: return 0x0200;
    case PadButton::Ls: return 0x0040;
    case PadButton::Rs: return 0x0080;
    case PadButton::Back: return 0x0020;
    case PadButton::Start: return 0x0010;
    case PadButton::Guide: return 0x0400;
    case PadButton::Up: return 0x0001;
    case PadButton::Down: return 0x0002;
    case PadButton::Left: return 0x0004;
    case PadButton::Right: return 0x0008;
    case PadButton::Lt:
    case PadButton::Rt: return 0;
    }
    return 0;
}

QString padButtonToken(PadButton button)
{
    switch (button) {
    case PadButton::A: return QStringLiteral("a");
    case PadButton::B: return QStringLiteral("b");
    case PadButton::X: return QStringLiteral("x");
    case PadButton::Y: return QStringLiteral("y");
    case PadButton::Lb: return QStringLiteral("lb");
    case PadButton::Rb: return QStringLiteral("rb");
    case PadButton::Lt: return QStringLiteral("lt");
    case PadButton::Rt: return QStringLiteral("rt");
    case PadButton::Ls: return QStringLiteral("ls");
    case PadButton::Rs: return QStringLiteral("rs");
    case PadButton::Back: return QStringLiteral("back");
    case PadButton::Start: return QStringLiteral("start");
    case PadButton::Guide: return QStringLiteral("guide");
    case PadButton::Up: return QStringLiteral("up");
    case PadButton::Down: return QStringLiteral("down");
    case PadButton::Left: return QStringLiteral("left");
    case PadButton::Right: return QStringLiteral("right");
    }
    return {};
}

std::optional<PadButton> padButtonFromToken(const QString &token)
{
    for (int index = 0; index <= static_cast<int>(PadButton::Right); ++index) {
        const auto button = static_cast<PadButton>(index);
        if (padButtonToken(button) == token) return button;
    }
    return std::nullopt;
}

QString shortcutToken(Shortcut shortcut)
{
    return shortcut == Shortcut::Controls ? QStringLiteral("controls") : QStringLiteral("stats");
}

QString shortcutLabel(Shortcut shortcut)
{
    return shortcut == Shortcut::Controls ? QStringLiteral("Stream HUD") : QStringLiteral("Toggle stats");
}

std::optional<Shortcut> shortcutFromToken(const QString &token)
{
    if (token == QStringLiteral("controls")) return Shortcut::Controls;
    if (token == QStringLiteral("stats")) return Shortcut::Stats;
    return std::nullopt;
}

float Vector::length() const
{
    return std::sqrt(x * x + y * y);
}

// MARK: Sources and modes

QString sourceToken(Config::Source source)
{
    using Source = Config::Source;
    switch (source) {
    case Source::ButtonDiamond: return QStringLiteral("button_diamond");
    case Source::Dpad: return QStringLiteral("dpad");
    case Source::Joystick: return QStringLiteral("joystick");
    case Source::RightJoystick: return QStringLiteral("right_joystick");
    case Source::LeftTrackpad: return QStringLiteral("left_trackpad");
    case Source::RightTrackpad: return QStringLiteral("right_trackpad");
    case Source::LeftTrigger: return QStringLiteral("left_trigger");
    case Source::RightTrigger: return QStringLiteral("right_trigger");
    case Source::Gyro: return QStringLiteral("gyro");
    case Source::Switches: return QStringLiteral("switch");
    case Source::System: return QStringLiteral("opennow_system");
    }
    return {};
}

std::optional<Config::Source> sourceFromToken(const QString &token)
{
    using Source = Config::Source;
    for (const Source source : {Source::ButtonDiamond, Source::Dpad, Source::Joystick, Source::RightJoystick,
                                Source::LeftTrackpad, Source::RightTrackpad, Source::LeftTrigger,
                                Source::RightTrigger, Source::Gyro, Source::Switches, Source::System}) {
        if (sourceToken(source) == token) return source;
    }
    return std::nullopt;
}

bool isSurface(Config::Source source)
{
    using Source = Config::Source;
    return source == Source::Joystick || source == Source::RightJoystick
           || source == Source::LeftTrackpad || source == Source::RightTrackpad;
}

bool isTrackpad(Config::Source source)
{
    return source == Config::Source::LeftTrackpad || source == Config::Source::RightTrackpad;
}

// MARK: Bindings and activators

Config::Binding Config::Binding::key(int code)
{
    return Binding{Kind::Key, code, Source::ButtonDiamond};
}

Config::Binding Config::Binding::mouseButton(int button)
{
    return Binding{Kind::MouseButton, button, Source::ButtonDiamond};
}

Config::Binding Config::Binding::wheel(int direction)
{
    return Binding{Kind::Wheel, direction, Source::ButtonDiamond};
}

Config::Binding Config::Binding::pad(PadButton button)
{
    return Binding{Kind::Pad, static_cast<int>(button), Source::ButtonDiamond};
}

Config::Binding Config::Binding::changeSet(int set)
{
    return Binding{Kind::ChangeSet, set, Source::ButtonDiamond};
}

Config::Binding Config::Binding::holdLayer(int layer)
{
    return Binding{Kind::HoldLayer, layer, Source::ButtonDiamond};
}

Config::Binding Config::Binding::addLayer(int layer)
{
    return Binding{Kind::AddLayer, layer, Source::ButtonDiamond};
}

Config::Binding Config::Binding::removeLayer(int layer)
{
    return Binding{Kind::RemoveLayer, layer, Source::ButtonDiamond};
}

Config::Binding Config::Binding::modeShift(Source source, int group)
{
    return Binding{Kind::ModeShift, group, source};
}

Config::Binding Config::Binding::shortcut(Shortcut action)
{
    return Binding{Kind::Shortcut, static_cast<int>(action), Source::ButtonDiamond};
}

PadButton Config::Binding::padButton() const
{
    return static_cast<PadButton>(value);
}

Shortcut Config::Binding::shortcutAction() const
{
    return static_cast<Shortcut>(value);
}

QString Config::Binding::shortTitle() const
{
    switch (kind) {
    case Kind::Key: return bindableKeyName(value);
    case Kind::MouseButton:
        switch (value) {
        case 1: return QStringLiteral("Left Click");
        case 2: return QStringLiteral("Middle Click");
        case 3: return QStringLiteral("Right Click");
        default: return QStringLiteral("Mouse %1").arg(value);
        }
    case Kind::Wheel: return value < 0 ? QStringLiteral("Scroll Down") : QStringLiteral("Scroll Up");
    case Kind::Pad: return padButtonToken(padButton()).toUpper();
    case Kind::ChangeSet: return QStringLiteral("Change Action Set");
    case Kind::HoldLayer: return QStringLiteral("Hold Layer");
    case Kind::AddLayer: return QStringLiteral("Add Layer");
    case Kind::RemoveLayer: return QStringLiteral("Remove Layer");
    case Kind::ModeShift: return QStringLiteral("Mode Shift");
    case Kind::Shortcut: return shortcutLabel(shortcutAction());
    }
    return {};
}

QString Config::Activator::displayLabel() const
{
    if (!label.isEmpty()) return label;
    QStringList titles;
    for (const Binding &binding : bindings) titles.append(binding.shortTitle());
    return titles.join(QStringLiteral("+"));
}

// MARK: Layout model

bool operator<(const Config::InputRef &left, const Config::InputRef &right)
{
    if (left.source != right.source) return left.source < right.source;
    return left.input < right.input;
}

bool Config::usesGyro() const
{
    for (const auto &[unusedKey, set] : sets) {
        const auto gyro = set.groups.find(Source::Gyro);
        if (gyro == set.groups.end()) continue;
        const auto group = groups.find(gyro->second);
        if (group == groups.end()) continue;
        if (group->second.mode != Mode::Disabled) return true;
    }
    return false;
}

QString Config::overrideKey(int set, Source source, const QString &input)
{
    return QStringLiteral("%1|%2|%3").arg(set).arg(sourceToken(source)).arg(input);
}

void Config::applyOverrides(const QHash<QString, QString> &overrides)
{
    std::map<QString, QString> ordered;
    for (auto it = overrides.cbegin(); it != overrides.cend(); ++it) ordered.emplace(it.key(), it.value());
    for (const auto &[key, token] : ordered) {
        const QStringList parts = splitSwift(key, u'|', 2, true);
        if (parts.size() != 3) continue;
        const auto setID = parseIntValue(parts[0]);
        const auto source = sourceFromToken(parts[1]);
        const auto action = Action::fromToken(token);
        if (!setID || !source || !action) continue;
        const auto setFound = sets.find(*setID);
        if (setFound == sets.end()) continue;

        ActionSet set = setFound->second;
        const int id = nextGroupID(*this);
        Group group;
        group.mode = Mode::Switches;
        const auto existing = set.groups.find(*source);
        if (existing != set.groups.end()) {
            const auto found = groups.find(existing->second);
            if (found != groups.end()) group = found->second;
        }
        group.id = id;
        Activator activator;
        activator.bindings = action->bindings();
        group.inputs[parts[2]] = {activator};
        groups[id] = group;
        set.groups[*source] = id;
        sets[*setID] = set;
    }
}

std::optional<Config> Config::fromVdf(const QString &text)
{
    const auto parsed = Vdf::parse(text);
    if (!parsed) return std::nullopt;
    const Vdf::Value *root = parsed->child(QStringLiteral("controller_mappings"));
    if (!root || root->entries().empty()) return std::nullopt;

    ImportNotes notes;
    Config config;
    config.controllerType = Vdf::stringOf(root->child(QStringLiteral("controller_type"))).value_or(QString());
    config.title = localized(Vdf::stringOf(root->child(QStringLiteral("title"))).value_or(QString()), *root);

    // A reference group stands for another one, so menus can be shared between sets.
    std::map<int, const Vdf::Value *> rawGroups;
    for (const Vdf::Value *group : root->all(QStringLiteral("group"))) {
        if (const auto id = parseIntValue(Vdf::stringOf(group->child(QStringLiteral("id"))))) rawGroups[*id] = group;
    }
    for (const auto &[id, raw] : rawGroups) {
        const Vdf::Value *resolved = raw;
        const Vdf::Value *settings = raw->child(QStringLiteral("settings"));
        const auto referenced = parseIntValue(Vdf::stringOf(settings ? settings->child(QStringLiteral("referenced_mode")) : nullptr));
        if (Vdf::stringOf(raw->child(QStringLiteral("mode"))) == QStringLiteral("reference") && referenced) {
            const auto other = rawGroups.find(*referenced);
            if (other != rawGroups.end()) resolved = other->second;
        }
        config.groups[id] = makeGroup(id, *resolved, notes);
    }

    // Titles of sets and layers, by lowercase name.
    struct Title {
        QString title;
        bool layer = false;
    };
    std::map<QString, Title> titles;
    if (const Vdf::Value *actions = root->child(QStringLiteral("actions"))) {
        for (const Vdf::Entry &entry : actions->entries()) {
            titles[entry.key.toLower()] = Title{
                localized(Vdf::stringOf(entry.value.child(QStringLiteral("title"))).value_or(entry.key), *root), false};
        }
    }
    if (const Vdf::Value *layers = root->child(QStringLiteral("action_layers"))) {
        for (const Vdf::Entry &entry : layers->entries()) {
            titles[entry.key.toLower()] = Title{
                localized(Vdf::stringOf(entry.value.child(QStringLiteral("title"))).value_or(entry.key), *root), true};
        }
    }

    std::optional<int> firstSet;
    for (const Vdf::Value *preset : root->all(QStringLiteral("preset"))) {
        const auto id = parseIntValue(Vdf::stringOf(preset->child(QStringLiteral("id"))));
        if (!id) continue;
        const QString name = Vdf::stringOf(preset->child(QStringLiteral("name"))).value_or(QString());
        const auto known = titles.find(name.toLower());
        ActionSet set;
        set.id = *id;
        set.title = known != titles.end() ? known->second.title : name;
        set.isLayer = known != titles.end() ? known->second.layer : false;
        if (const Vdf::Value *bindings = preset->child(QStringLiteral("group_source_bindings"))) {
            for (const Vdf::Entry &binding : bindings->entries()) {
                const QStringList words = splitSwift(Vdf::stringOf(&binding.value).value_or(QString()), u' ', INT_MAX, true);
                const auto groupID = parseIntValue(binding.key);
                if (!groupID || words.size() < 2 || words[1] != QStringLiteral("active")
                    || words.contains(QStringLiteral("modeshift"))) {
                    continue;
                }
                const auto source = sourceFromToken(words[0]);
                if (!source || *source == Source::System) {
                    notes.unsupportedSources.insert(words[0]);
                    continue;
                }
                set.groups[*source] = *groupID;
            }
        }
        config.sets[*id] = set;
        if (!firstSet && !set.isLayer) firstSet = *id;
    }
    if (config.sets.empty()) return std::nullopt;
    config.defaultSet = firstSet ? *firstSet : config.sets.begin()->first;

    sendNativeActionsAsGamepad(config);
    addSystemDefaults(config);
    config.notes = notes.sentences();
    return config;
}

// MARK: Actions

Action Action::none()
{
    return Action(Kind::None, 0);
}

Action Action::pad(PadButton button)
{
    return Action(Kind::Pad, static_cast<int>(button));
}

Action Action::key(int code)
{
    return Action(Kind::Key, code);
}

Action Action::mouse(int button)
{
    return Action(Kind::Mouse, button);
}

Action Action::wheel(int direction)
{
    return Action(Kind::Wheel, direction);
}

Action Action::shortcut(Shortcut action)
{
    return Action(Kind::Shortcut, static_cast<int>(action));
}

std::optional<Action> Action::fromToken(const QString &token)
{
    // Split on the first colon only; the value may itself be empty.
    const QStringList parts = splitSwift(token, u':', 1, true);
    if (parts.isEmpty()) return std::nullopt;
    const QString kind = parts.first();
    const QString value = parts.size() > 1 ? parts[1] : QString();
    if (kind == QStringLiteral("none")) return none();
    if (kind == QStringLiteral("pad")) {
        if (const auto button = padButtonFromToken(value)) return pad(*button);
        return std::nullopt;
    }
    if (kind == QStringLiteral("key")) {
        const auto code = parseIntValue(value);
        if (!code || *code < 1 || *code > 254) return std::nullopt;
        return key(*code);
    }
    if (kind == QStringLiteral("mouse")) {
        if (value == QStringLiteral("left")) return mouse(1);
        if (value == QStringLiteral("middle")) return mouse(2);
        if (value == QStringLiteral("right")) return mouse(3);
        return std::nullopt;
    }
    if (kind == QStringLiteral("wheel")) {
        if (value == QStringLiteral("up")) return wheel(1);
        if (value == QStringLiteral("down")) return wheel(-1);
        return std::nullopt;
    }
    if (kind == QStringLiteral("app")) {
        // The shortcut "none" is not one a control can send.
        if (const auto action = shortcutFromToken(value)) return shortcut(*action);
        return std::nullopt;
    }
    return std::nullopt;
}

QString Action::token() const
{
    switch (kind_) {
    case Kind::None: return QStringLiteral("none");
    case Kind::Pad: return QStringLiteral("pad:%1").arg(padButtonToken(static_cast<PadButton>(value_)));
    case Kind::Key: return QStringLiteral("key:%1").arg(value_);
    case Kind::Mouse:
        return QStringLiteral("mouse:%1").arg(value_ == 2 ? QStringLiteral("middle")
                                              : value_ == 3 ? QStringLiteral("right")
                                                            : QStringLiteral("left"));
    case Kind::Wheel: return QStringLiteral("wheel:%1").arg(value_ < 0 ? QStringLiteral("down") : QStringLiteral("up"));
    case Kind::Shortcut: return QStringLiteral("app:%1").arg(shortcutToken(static_cast<Shortcut>(value_)));
    }
    return {};
}

QList<Config::Binding> Action::bindings() const
{
    switch (kind_) {
    case Kind::None: return {};
    case Kind::Pad: return {Config::Binding::pad(static_cast<PadButton>(value_))};
    case Kind::Key: return {Config::Binding::key(value_)};
    case Kind::Mouse: return {Config::Binding::mouseButton(value_)};
    case Kind::Wheel: return {Config::Binding::wheel(value_)};
    case Kind::Shortcut: return {Config::Binding::shortcut(static_cast<Shortcut>(value_))};
    }
    return {};
}

// MARK: Key names

QString bindableKeyName(int code)
{
    // The right-hand modifiers read the same as the left-hand ones that are offered.
    if (code == 0xa1) code = 0xa0;
    else if (code == 0xa3) code = 0xa2;
    else if (code == 0xa5) code = 0xa4;

    static const std::map<int, QString> names = [] {
        std::map<int, QString> table{
            {0x20, QStringLiteral("Space")}, {0x0d, QStringLiteral("Enter")}, {0x1b, QStringLiteral("Esc")},
            {0x09, QStringLiteral("Tab")}, {0x08, QStringLiteral("Backspace")}, {0xa0, QStringLiteral("Shift")},
            {0xa2, QStringLiteral("Ctrl")}, {0xa4, QStringLiteral("Alt")},
            {0x26, QStringLiteral("Up")}, {0x28, QStringLiteral("Down")}, {0x25, QStringLiteral("Left")},
            {0x27, QStringLiteral("Right")}, {0x24, QStringLiteral("Home")}, {0x23, QStringLiteral("End")},
            {0x21, QStringLiteral("Page Up")}, {0x22, QStringLiteral("Page Down")},
            {0x2d, QStringLiteral("Insert")}, {0x2e, QStringLiteral("Delete")},
            {0xc0, QStringLiteral("`")}, {0xbd, QStringLiteral("-")}, {0xbb, QStringLiteral("=")},
            {0xdb, QStringLiteral("[")}, {0xdd, QStringLiteral("]")}, {0xdc, QStringLiteral("\\")},
            {0xba, QStringLiteral(";")}, {0xde, QStringLiteral("'")}, {0xbc, QStringLiteral(",")},
            {0xbe, QStringLiteral(".")}, {0xbf, QStringLiteral("/")},
        };
        for (int letter = 0x41; letter <= 0x5a; ++letter) table[letter] = QString(QChar(static_cast<char16_t>(letter)));
        for (int digit = 0x30; digit <= 0x39; ++digit) table[digit] = QString(QChar(static_cast<char16_t>(digit)));
        for (int number = 1; number <= 12; ++number) table[0x6f + number] = QStringLiteral("F%1").arg(number);
        return table;
    }();
    const auto found = names.find(code);
    if (found != names.end()) return found->second;
    return QStringLiteral("Key %1").arg(code);
}

size_t qHash(const Config::InputRef &ref, size_t seed) noexcept
{
    return qHashMulti(seed, static_cast<int>(ref.source), ref.input);
}

size_t qHash(const Config::Binding &binding, size_t seed) noexcept
{
    return qHashMulti(seed, static_cast<int>(binding.kind), binding.value, static_cast<int>(binding.source));
}

} // namespace SteamInput
