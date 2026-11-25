#pragma once

#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QStringList>
#include <QUrl>
#include <QVariantList>

#include <optional>

#include "input/SteamInputConfig.h"

class QNetworkAccessManager;

// Layouts imported from Steam: the files exactly as Steam published them, with a small index.
// Community layouts are fetched by their Steam Workshop ID through Steam's public file-details
// service, which needs no account or key.
class SteamLayoutLibrary final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList layouts READ layouts NOTIFY layoutsChanged)
    Q_PROPERTY(bool importing READ importing NOTIFY importingChanged)
    Q_PROPERTY(QString message READ message NOTIFY messageChanged)

public:
    static constexpr qint64 maximumFileBytes = 2'000'000;

    // `directory` and `network` are for tests; by default layouts live in the app's data folder.
    explicit SteamLayoutLibrary(QObject *parent = nullptr, QString directory = {},
                                QNetworkAccessManager *network = nullptr);

    [[nodiscard]] QVariantList layouts() const;
    [[nodiscard]] bool importing() const { return m_importing; }
    [[nodiscard]] QString message() const { return m_message; }
    [[nodiscard]] std::optional<SteamInput::Config> config(const QString &id) const;

    // The Workshop ID in a pasted link or number. `steam://controllerconfig/<app>/<id>` and
    // Workshop page links both end in it.
    Q_INVOKABLE static QString workshopId(const QString &text);
    // Saves a layout file and returns its ID, or nothing if it is not a layout. Importing the same
    // Workshop layout again replaces the earlier copy.
    Q_INVOKABLE QString importText(const QString &vdf, const QString &workshopId = {},
                                   const QString &fallbackTitle = {});
    Q_INVOKABLE void importFile(const QUrl &file);
    // Downloads the layout a Steam link or Workshop ID points at and saves it.
    Q_INVOKABLE void importFromSteam(const QString &reference);
    Q_INVOKABLE void remove(const QString &id);

signals:
    void layoutsChanged();
    void importingChanged();
    void messageChanged();
    void layoutImported(const QString &id);

private:
    struct Entry {
        QString id;
        QString title;
        QString controllerType;
        QString workshopId;
        QDateTime importedAt;
        QStringList notes;
    };

    [[nodiscard]] QString filePath(const QString &id) const;
    void saveIndex() const;
    void setMessage(const QString &message);
    void setImporting(bool importing);
    void finishDownload(const QString &id, const QString &title, const QUrl &file);

    QString m_directory;
    QNetworkAccessManager *m_network = nullptr;
    QList<Entry> m_entries;
    mutable QHash<QString, SteamInput::Config> m_configs;
    bool m_importing = false;
    QString m_message;
};
