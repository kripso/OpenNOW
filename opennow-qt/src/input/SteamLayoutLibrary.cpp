#include "input/SteamLayoutLibrary.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>

namespace {
constexpr int steamLayoutsApp = 241100;
constexpr int requestTimeoutMs = 20'000;
constexpr int maximumTitleChars = 120;

QString readText(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || file.size() > SteamLayoutLibrary::maximumFileBytes) return {};
    return QString::fromUtf8(file.readAll());
}

bool writeAtomically(const QString &path, const QByteArray &bytes)
{
    QSaveFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size() && file.commit();
}
}

SteamLayoutLibrary::SteamLayoutLibrary(QObject *parent, QString directory, QNetworkAccessManager *network)
    : QObject(parent), m_directory(std::move(directory)), m_network(network)
{
    if (m_directory.isEmpty()) {
        m_directory = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
            + QStringLiteral("/SteamLayouts");
    }
    QDir().mkpath(m_directory);
    if (!m_network) m_network = new QNetworkAccessManager(this);
    QFile index(m_directory + QStringLiteral("/index.json"));
    if (!index.open(QIODevice::ReadOnly)) return;
    const auto stored = QJsonDocument::fromJson(index.readAll()).array();
    for (const auto &value : stored) {
        const auto object = value.toObject();
        Entry entry;
        entry.id = object.value(QStringLiteral("id")).toString();
        entry.title = object.value(QStringLiteral("title")).toString();
        entry.controllerType = object.value(QStringLiteral("controllerType")).toString();
        entry.workshopId = object.value(QStringLiteral("workshopId")).toString();
        entry.importedAt = QDateTime::fromString(object.value(QStringLiteral("importedAt")).toString(), Qt::ISODate);
        for (const auto &note : object.value(QStringLiteral("notes")).toArray()) entry.notes.append(note.toString());
        // IDs become file names, so only the ones this class makes are accepted.
        if (QUuid::fromString(entry.id).isNull() || !QFileInfo::exists(filePath(entry.id))) continue;
        m_entries.append(entry);
    }
    // What is unsupported depends on this version of the app, not the one that imported the file.
    for (auto &entry : m_entries) {
        if (const auto layout = config(entry.id)) entry.notes = layout->notes;
    }
}

QVariantList SteamLayoutLibrary::layouts() const
{
    QVariantList result;
    for (const auto &entry : m_entries) {
        result.append(QVariantMap{
            {QStringLiteral("id"), entry.id},
            {QStringLiteral("title"), entry.title},
            {QStringLiteral("controllerType"), entry.controllerType},
            {QStringLiteral("workshopId"), entry.workshopId},
            {QStringLiteral("notes"), entry.notes},
        });
    }
    return result;
}

std::optional<SteamInput::Config> SteamLayoutLibrary::config(const QString &id) const
{
    const auto known = std::any_of(m_entries.cbegin(), m_entries.cend(), [&](const Entry &entry) { return entry.id == id; });
    if (!known) return std::nullopt;
    if (const auto cached = m_configs.constFind(id); cached != m_configs.cend()) return *cached;
    auto config = SteamInput::Config::fromVdf(readText(filePath(id)));
    if (config) m_configs.insert(id, *config);
    return config;
}

QString SteamLayoutLibrary::workshopId(const QString &text)
{
    QString last;
    QString current;
    const auto close = [&] {
        if (current.size() >= 6) last = current;
        current.clear();
    };
    for (const auto character : text) {
        if (character >= QLatin1Char('0') && character <= QLatin1Char('9')) current.append(character);
        else close();
    }
    close();
    return last.size() <= 20 ? last : QString();
}

QString SteamLayoutLibrary::importText(const QString &vdf, const QString &workshopId, const QString &fallbackTitle)
{
    const auto bytes = vdf.toUtf8();
    if (bytes.size() > maximumFileBytes) {
        setMessage(QStringLiteral("That file is too large to be a layout."));
        return {};
    }
    const auto config = SteamInput::Config::fromVdf(vdf);
    if (!config) {
        setMessage(QStringLiteral("That file is not a Steam Input layout."));
        return {};
    }
    const auto existing = workshopId.isEmpty() ? m_entries.cend()
        : std::find_if(m_entries.cbegin(), m_entries.cend(), [&](const Entry &entry) { return entry.workshopId == workshopId; });
    Entry entry;
    entry.id = existing != m_entries.cend() ? existing->id : QUuid::createUuid().toString(QUuid::WithoutBraces);
    entry.title = config->title.isEmpty() || config->title.startsWith(QLatin1Char('#')) ? fallbackTitle : config->title;
    if (entry.title.isEmpty()) entry.title = QStringLiteral("Steam Layout");
    entry.title.truncate(maximumTitleChars);
    entry.controllerType = config->controllerType;
    entry.workshopId = workshopId;
    entry.importedAt = QDateTime::currentDateTimeUtc();
    entry.notes = config->notes;
    if (!writeAtomically(filePath(entry.id), bytes)) {
        setMessage(QStringLiteral("The layout could not be saved."));
        return {};
    }
    m_configs.insert(entry.id, *config);
    m_entries.removeIf([&](const Entry &other) { return other.id == entry.id; });
    m_entries.prepend(entry);
    saveIndex();
    setMessage(entry.notes.isEmpty() ? QStringLiteral("Imported %1.").arg(entry.title)
        : QStringLiteral("Imported %1. Not all of it is supported: %2").arg(entry.title, entry.notes.join(QLatin1Char(' '))));
    emit layoutsChanged();
    emit layoutImported(entry.id);
    return entry.id;
}

void SteamLayoutLibrary::importFile(const QUrl &file)
{
    const auto path = file.toLocalFile();
    const QFileInfo info(path);
    if (!info.isFile() || info.size() > maximumFileBytes) {
        setMessage(QStringLiteral("That file is not a Steam Input layout."));
        return;
    }
    importText(readText(path), {}, info.completeBaseName());
}

void SteamLayoutLibrary::remove(const QString &id)
{
    const auto removed = m_entries.removeIf([&](const Entry &entry) { return entry.id == id; });
    if (removed == 0) return;
    m_configs.remove(id);
    QFile::remove(filePath(id));
    saveIndex();
    emit layoutsChanged();
}

void SteamLayoutLibrary::importFromSteam(const QString &reference)
{
    const auto id = workshopId(reference);
    if (id.isEmpty()) {
        setMessage(QStringLiteral("That does not contain a Steam layout link or ID."));
        return;
    }
    if (m_importing) return;
    setImporting(true);
    setMessage({});
    QNetworkRequest request(QUrl(QStringLiteral("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/x-www-form-urlencoded"));
    request.setTransferTimeout(requestTimeoutMs);
    auto *reply = m_network->post(request, QStringLiteral("itemcount=1&publishedfileids[0]=%1").arg(id).toUtf8());
    connect(reply, &QNetworkReply::finished, this, [this, reply, id] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            setImporting(false);
            setMessage(QStringLiteral("Steam could not be reached: %1").arg(reply->errorString()));
            return;
        }
        const auto details = QJsonDocument::fromJson(reply->readAll()).object()
            .value(QStringLiteral("response")).toObject()
            .value(QStringLiteral("publishedfiledetails")).toArray().first().toObject();
        // Result 1 is success; the link must be Steam's own HTTPS download for a layout file.
        const QUrl file(details.value(QStringLiteral("file_url")).toString());
        if (details.value(QStringLiteral("result")).toInt() != 1 || file.scheme() != QStringLiteral("https")
                || !file.host().endsWith(QStringLiteral("steamusercontent.com"))) {
            setImporting(false);
            setMessage(QStringLiteral("Steam has no public layout with that ID."));
            return;
        }
        if (details.value(QStringLiteral("consumer_app_id")).toInt() != steamLayoutsApp) {
            setImporting(false);
            setMessage(QStringLiteral("That file is not a Steam Input layout."));
            return;
        }
        finishDownload(id, details.value(QStringLiteral("title")).toString(), file);
    });
}

void SteamLayoutLibrary::finishDownload(const QString &id, const QString &title, const QUrl &file)
{
    QNetworkRequest request(file);
    request.setTransferTimeout(requestTimeoutMs);
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::downloadProgress, reply, [reply](qint64 received, qint64) {
        if (received > maximumFileBytes) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, id, title] {
        reply->deleteLater();
        setImporting(false);
        if (reply->error() != QNetworkReply::NoError) {
            setMessage(QStringLiteral("Steam could not be reached: %1").arg(reply->errorString()));
            return;
        }
        importText(QString::fromUtf8(reply->readAll()), id, title);
    });
}

QString SteamLayoutLibrary::filePath(const QString &id) const
{
    return m_directory + QLatin1Char('/') + id + QStringLiteral(".vdf");
}

void SteamLayoutLibrary::saveIndex() const
{
    QJsonArray stored;
    for (const auto &entry : m_entries) {
        stored.append(QJsonObject{
            {QStringLiteral("id"), entry.id},
            {QStringLiteral("title"), entry.title},
            {QStringLiteral("controllerType"), entry.controllerType},
            {QStringLiteral("workshopId"), entry.workshopId},
            {QStringLiteral("importedAt"), entry.importedAt.toString(Qt::ISODate)},
            {QStringLiteral("notes"), QJsonArray::fromStringList(entry.notes)},
        });
    }
    writeAtomically(m_directory + QStringLiteral("/index.json"), QJsonDocument(stored).toJson(QJsonDocument::Compact));
}

void SteamLayoutLibrary::setMessage(const QString &message)
{
    if (m_message == message) return;
    m_message = message;
    emit messageChanged();
}

void SteamLayoutLibrary::setImporting(bool importing)
{
    if (m_importing == importing) return;
    m_importing = importing;
    emit importingChanged();
}
