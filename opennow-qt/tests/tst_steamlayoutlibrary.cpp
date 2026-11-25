#include "input/SteamLayoutLibrary.h"

#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

namespace {
const auto layoutText = QStringLiteral(R"vdf(
"controller_mappings"
{
    "title" "Library Layout"
    "controller_type" "controller_triton"
    "group" { "id" "0" "mode" "four_buttons" "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press Q" } } } } } }
    "group" { "id" "1" "mode" "switches" "inputs" { "button_back_left" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action SHOW_KEYBOARD" } } } } } }
    "preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "button_diamond active" "1" "switch active" } }
}
)vdf");
}

class SteamLayoutLibraryTest final : public QObject
{
    Q_OBJECT

private slots:
    void workshopIdentifiersAreFoundInLinksAndPlainNumbers()
    {
        QCOMPARE(SteamLayoutLibrary::workshopId(QStringLiteral("steam://controllerconfig/413080/2866090215")),
                 QStringLiteral("2866090215"));
        QCOMPARE(SteamLayoutLibrary::workshopId(
                     QStringLiteral("https://steamcommunity.com/sharedfiles/filedetails/?id=2866090215&searchtext=")),
                 QStringLiteral("2866090215"));
        QCOMPARE(SteamLayoutLibrary::workshopId(QStringLiteral("  2866090215 ")), QStringLiteral("2866090215"));
        QVERIFY(SteamLayoutLibrary::workshopId(QStringLiteral("steam://controllerconfig/42/7")).isEmpty());
        QVERIFY(SteamLayoutLibrary::workshopId(QStringLiteral("no numbers here")).isEmpty());
    }

    void importedLayoutsAreKeptAcrossLaunches()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QString id;
        {
            SteamLayoutLibrary library(nullptr, directory.path());
            QSignalSpy changed(&library, &SteamLayoutLibrary::layoutsChanged);
            QSignalSpy imported(&library, &SteamLayoutLibrary::layoutImported);
            QVERIFY(library.importText(QStringLiteral("nothing useful")).isEmpty());
            QCOMPARE(library.message(), QStringLiteral("That file is not a Steam Input layout."));
            QVERIFY(library.layouts().isEmpty());

            id = library.importText(layoutText, QStringLiteral("2866090215"), QStringLiteral("Fallback"));
            QVERIFY(!id.isEmpty());
            QCOMPARE(changed.size(), 1);
            QCOMPARE(imported.last().at(0).toString(), id);
            const auto entry = library.layouts().first().toMap();
            QCOMPARE(entry.value(QStringLiteral("title")).toString(), QStringLiteral("Library Layout"));
            QCOMPARE(entry.value(QStringLiteral("controllerType")).toString(), QStringLiteral("controller_triton"));
            // What the layout uses that has no meaning outside Steam is told to the player.
            QCOMPARE(entry.value(QStringLiteral("notes")).toStringList().size(), 1);
            QVERIFY(library.message().contains(QStringLiteral("show_keyboard")));
            // The same Workshop layout imported again replaces the first copy.
            QCOMPARE(library.importText(layoutText, QStringLiteral("2866090215")), id);
            QCOMPARE(library.layouts().size(), 1);
            QCOMPARE(library.config(id)->title, QStringLiteral("Library Layout"));
            QVERIFY(!library.config(QStringLiteral("missing")).has_value());
        }
        SteamLayoutLibrary reopened(nullptr, directory.path());
        QCOMPARE(reopened.layouts().size(), 1);
        QVERIFY(reopened.config(id).has_value());
        reopened.remove(id);
        QVERIFY(reopened.layouts().isEmpty());
        QVERIFY(!reopened.config(id).has_value());
        QVERIFY(SteamLayoutLibrary(nullptr, directory.path()).layouts().isEmpty());
    }

    void anIndexNamingAFileOutsideTheLibraryIsIgnored()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QFile index(directory.path() + QStringLiteral("/index.json"));
        QVERIFY(index.open(QIODevice::WriteOnly));
        index.write(R"([{"id":"../../outside","title":"Escapes"},{"id":"7b1f0c9e-3f5d-4a52-9f0c-0d6a4f6a1c11","title":"Gone"}])");
        index.close();
        QVERIFY(SteamLayoutLibrary(nullptr, directory.path()).layouts().isEmpty());
    }
};

QTEST_GUILESS_MAIN(SteamLayoutLibraryTest)
#include "tst_steamlayoutlibrary.moc"
