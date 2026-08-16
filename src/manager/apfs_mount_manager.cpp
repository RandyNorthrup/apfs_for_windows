// Copyright (c) 2026 Randy Northrup. All rights reserved.

#include <QApplication>
#include <QAction>
#include <QBrush>
#include <QClipboard>
#include <QColor>
#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QFont>
#include <QGuiApplication>
#include <QHeaderView>
#include <QIcon>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
#include <QInputDialog>
#include <QPainter>
#include <QPen>
#include <QPlainTextEdit>
#include <QLineEdit>
#include <QLocalServer>
#include <QLocalSocket>
#include <QPixmap>
#include <QProcess>
#include <QPushButton>
#include <QRect>
#include <QScreen>
#include <QSplitter>
#include <QStatusBar>
#include <QStringList>
#include <QStyle>
#include <QSystemTrayIcon>
#include <QTableWidget>
#include <QTextStream>
#include <QToolBar>
#include <QUrl>
#include <QVBoxLayout>

namespace {

constexpr char kManagerInstanceServer[] = "ApfsForWindowsMountManager.Instance";

void printJson(const QJsonObject& object) {
    QTextStream(stdout) << QJsonDocument(object).toJson(QJsonDocument::Indented);
}

QString installedServiceExe() {
#ifdef Q_OS_WIN
    const QString programFiles = qEnvironmentVariable("ProgramFiles", QStringLiteral("C:\\Program Files"));
    return QDir(programFiles).filePath(QStringLiteral("APFS for Windows/apfs_mount_service.exe"));
#else
    return {};
#endif
}

QString serviceExePath() {
    const QString appLocal =
        QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("apfs_mount_service.exe"));
    if (QFileInfo::exists(appLocal)) {
        return appLocal;
    }
    const QString installed = installedServiceExe();
    if (QFileInfo::exists(installed)) {
        return installed;
    }
    return appLocal;
}

QJsonObject runServiceCommand(const QStringList& args, int* exitCode = nullptr) {
    QProcess process;
    process.start(serviceExePath(), args);
    if (!process.waitForFinished(30000)) {
        process.kill();
        process.waitForFinished(3000);
        if (exitCode) {
            *exitCode = 124;
        }
        return QJsonObject{{QStringLiteral("ok"), false},
                           {QStringLiteral("error"), QStringLiteral("service command timed out")},
                           {QStringLiteral("args"), QJsonArray::fromStringList(args)}};
    }

    if (exitCode) {
        *exitCode = process.exitCode();
    }
    const QByteArray stdoutBytes = process.readAllStandardOutput();
    const QByteArray stderrBytes = process.readAllStandardError();
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(stdoutBytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        return QJsonObject{{QStringLiteral("ok"), false},
                           {QStringLiteral("exit_code"), process.exitCode()},
                           {QStringLiteral("stdout"), QString::fromUtf8(stdoutBytes)},
                           {QStringLiteral("stderr"), QString::fromUtf8(stderrBytes)},
                           {QStringLiteral("parse_error"), parseError.errorString()}};
    }
    QJsonObject object = document.object();
    object.insert(QStringLiteral("ok"), process.exitCode() == 0);
    if (!stderrBytes.isEmpty()) {
        object.insert(QStringLiteral("stderr"), QString::fromUtf8(stderrBytes));
    }
    return object;
}

QString compactJson(const QJsonObject& object) {
    return QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Indented));
}

QIcon stackedApfsIcon() {
    QPixmap pixmap(256, 256);
    pixmap.fill(Qt::transparent);

    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing, true);
    const QRectF background(14, 14, 228, 228);
    painter.setPen(QPen(QColor(80, 176, 214), 8));
    painter.setBrush(QColor(20, 42, 58));
    painter.drawRoundedRect(background, 28, 28);

    painter.setPen(QPen(QColor(80, 176, 214), 6));
    painter.drawLine(QPointF(48, 128), QPointF(208, 128));

    QFont font(QStringLiteral("Segoe UI"));
    font.setBold(true);
    font.setPixelSize(78);
    painter.setFont(font);
    painter.setPen(Qt::white);
    painter.drawText(QRect(0, 28, 256, 92), Qt::AlignCenter, QStringLiteral("AP"));
    painter.drawText(QRect(0, 136, 256, 88), Qt::AlignCenter, QStringLiteral("FS"));
    painter.end();

    return QIcon(pixmap);
}

QString modeText(const QJsonObject& mount) {
    const bool readOnly = mount.value(QStringLiteral("read_only")).toBool(true);
    const bool rawWrites = mount.value(QStringLiteral("allow_raw_writes")).toBool(false);
    if (readOnly) {
        return QStringLiteral("Read-only");
    }
    return rawWrites ? QStringLiteral("Read/write raw-enabled") : QStringLiteral("Read/write image");
}

QString entryText(const QJsonObject& mount) {
    const QJsonArray entries = mount.value(QStringLiteral("entries")).toArray();
    QStringList names;
    for (const auto& value : entries) {
        names.append(value.toObject().value(QStringLiteral("name")).toString());
        if (names.size() == 4) {
            break;
        }
    }
    if (entries.size() > names.size()) {
        names.append(QStringLiteral("+%1").arg(entries.size() - names.size()));
    }
    return names.join(QStringLiteral(", "));
}

class MountManagerWindow final : public QMainWindow {
public:
    MountManagerWindow() {
        setWindowTitle(QStringLiteral("APFS for Windows"));
        setMinimumSize(760, 460);

        auto* central = new QWidget(this);
        auto* layout = new QVBoxLayout(central);
        layout->setContentsMargins(10, 10, 10, 10);
        layout->setSpacing(8);

        auto* title = new QLabel(QStringLiteral("Mounted APFS Volumes"), central);
        title->setObjectName(QStringLiteral("titleLabel"));
        QFont titleFont = title->font();
        titleFont.setPointSize(titleFont.pointSize() + 2);
        titleFont.setBold(true);
        title->setFont(titleFont);
        title->setAccessibleName(QStringLiteral("Mounted APFS volumes"));
        layout->addWidget(title);

        splitter_ = new QSplitter(Qt::Vertical, central);
        splitter_->setChildrenCollapsible(false);
        table_ = new QTableWidget(splitter_);
        table_->setColumnCount(5);
        table_->setHorizontalHeaderLabels({QStringLiteral("Mount"),
                                           QStringLiteral("Target"),
                                           QStringLiteral("Mode"),
                                           QStringLiteral("State"),
                                           QStringLiteral("Entries")});
        table_->setSelectionBehavior(QAbstractItemView::SelectRows);
        table_->setSelectionMode(QAbstractItemView::SingleSelection);
        table_->setEditTriggers(QAbstractItemView::NoEditTriggers);
        table_->setAlternatingRowColors(true);
        table_->setAccessibleName(QStringLiteral("APFS mount table"));
        table_->setAccessibleDescription(QStringLiteral("List of configured APFS mounts."));
        table_->horizontalHeader()->setStretchLastSection(true);
        table_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::ResizeToContents);
        table_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
        table_->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        table_->horizontalHeader()->setSectionResizeMode(3, QHeaderView::ResizeToContents);

        detail_ = new QPlainTextEdit(splitter_);
        detail_->setReadOnly(true);
        detail_->setLineWrapMode(QPlainTextEdit::NoWrap);
        detail_->setAccessibleName(QStringLiteral("Service health JSON"));
        detail_->setAccessibleDescription(QStringLiteral("Raw service health response."));
        splitter_->addWidget(table_);
        splitter_->addWidget(detail_);
        splitter_->setStretchFactor(0, 4);
        splitter_->setStretchFactor(1, 2);
        layout->addWidget(splitter_);
        setCentralWidget(central);

        auto* toolbar = addToolBar(QStringLiteral("Mount actions"));
        toolbar->setMovable(false);
        toolbar->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
        refreshButton_ = new QPushButton(style()->standardIcon(QStyle::SP_BrowserReload),
                                         QStringLiteral("Refresh"),
                                         toolbar);
        discoverButton_ = new QPushButton(style()->standardIcon(QStyle::SP_DriveHDIcon),
                                          QStringLiteral("Discover"),
                                          toolbar);
        openButton_ = new QPushButton(style()->standardIcon(QStyle::SP_DirOpenIcon),
                                      QStringLiteral("Open"),
                                      toolbar);
        letterButton_ = new QPushButton(style()->standardIcon(QStyle::SP_DriveHDIcon),
                                        QStringLiteral("Letter"),
                                        toolbar);
        modeButton_ = new QPushButton(style()->standardIcon(QStyle::SP_DialogApplyButton),
                                      QStringLiteral("Mode"),
                                      toolbar);
        policyButton_ = new QPushButton(style()->standardIcon(QStyle::SP_DialogApplyButton),
                                        QStringLiteral("Disable"),
                                        toolbar);
        unmountButton_ = new QPushButton(style()->standardIcon(QStyle::SP_DialogCloseButton),
                                         QStringLiteral("Unmount"),
                                         toolbar);
        copyButton_ = new QPushButton(style()->standardIcon(QStyle::SP_FileDialogDetailedView),
                                      QStringLiteral("Copy JSON"),
                                      toolbar);
        for (QPushButton* button :
             {refreshButton_,
              discoverButton_,
              openButton_,
              letterButton_,
              modeButton_,
              policyButton_,
              unmountButton_,
              copyButton_}) {
            button->setMinimumHeight(32);
            button->setFocusPolicy(Qt::StrongFocus);
            toolbar->addWidget(button);
        }
        refreshButton_->setAccessibleName(QStringLiteral("Refresh mount list"));
        discoverButton_->setAccessibleName(QStringLiteral("Discover APFS volumes"));
        openButton_->setAccessibleName(QStringLiteral("Open selected mount in Explorer"));
        letterButton_->setAccessibleName(QStringLiteral("Change selected APFS drive letter"));
        modeButton_->setAccessibleName(QStringLiteral("Change selected APFS read write mode"));
        policyButton_->setAccessibleName(QStringLiteral("Enable or disable selected APFS automount"));
        unmountButton_->setAccessibleName(QStringLiteral("Unmount selected APFS volume"));
        copyButton_->setAccessibleName(QStringLiteral("Copy service health JSON"));

        connect(refreshButton_, &QPushButton::clicked, this, [this]() { refreshHealth(); });
        connect(discoverButton_, &QPushButton::clicked, this, [this]() { runDiscovery(); });
        connect(openButton_, &QPushButton::clicked, this, [this]() { openSelectedMount(); });
        connect(letterButton_, &QPushButton::clicked, this, [this]() { changeSelectedMountLetter(); });
        connect(modeButton_, &QPushButton::clicked, this, [this]() { changeSelectedMountMode(); });
        connect(policyButton_, &QPushButton::clicked, this, [this]() { changeSelectedMountPolicy(); });
        connect(unmountButton_, &QPushButton::clicked, this, [this]() { unmountSelectedMount(); });
        connect(copyButton_, &QPushButton::clicked, this, [this]() { copyHealthJson(); });
        connect(table_, &QTableWidget::itemSelectionChanged, this, [this]() { updateButtonState(); });

        statusBar()->showMessage(QStringLiteral("Ready"));
        refreshHealth();
        fitToScreen();
    }

    QJsonObject selfTestResult(const QIcon& trayIcon, const QMenu& trayMenu) const {
        QJsonArray trayActions;
        bool hasTrayOpenAction = false;
        bool hasTrayExitAction = false;
        for (const QAction* action : trayMenu.actions()) {
            if (!action || action->isSeparator()) {
                continue;
            }
            trayActions.append(action->text());
            hasTrayOpenAction = hasTrayOpenAction || action->text() == QStringLiteral("Open");
            hasTrayExitAction = hasTrayExitAction || action->text() == QStringLiteral("Exit");
        }
        return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_manager")},
                           {QStringLiteral("ui"), QStringLiteral("available")},
                           {QStringLiteral("accessible_table_name"),
                            table_->accessibleName()},
                           {QStringLiteral("mount_rows"), table_->rowCount()},
                           {QStringLiteral("health_ok"),
                            health_.value(QStringLiteral("ok")).toBool(false)},
                           {QStringLiteral("has_refresh_button"),
                            !refreshButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_discover_button"),
                            !discoverButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_open_button"),
                            !openButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_letter_button"),
                            !letterButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_mode_button"),
                            !modeButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_policy_button"),
                            !policyButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_unmount_button"),
                            !unmountButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_copy_button"),
                            !copyButton_->accessibleName().isEmpty()},
                           {QStringLiteral("tray_icon_available"), !trayIcon.isNull()},
                           {QStringLiteral("tray_context_actions"), trayActions},
                           {QStringLiteral("has_tray_open_action"), hasTrayOpenAction},
                           {QStringLiteral("has_tray_exit_action"), hasTrayExitAction},
                           {QStringLiteral("quit_on_last_window_closed"),
                            QApplication::quitOnLastWindowClosed()}};
    }

private:
    void fitToScreen() {
        const QScreen* screen = QGuiApplication::primaryScreen();
        if (!screen) {
            return;
        }
        const QRect available = screen->availableGeometry();
        resize(std::min(width(), available.width() - 80),
               std::min(height(), available.height() - 80));
    }

    QJsonObject selectedMount() const {
        const int row = table_->currentRow();
        const QJsonArray mounts = health_.value(QStringLiteral("mounts")).toArray();
        if (row < 0 || row >= mounts.size()) {
            return {};
        }
        return mounts.at(row).toObject();
    }

    void setBusy(bool busy) {
        if (busy == busy_) {
            return;
        }
        busy_ = busy;
        for (QPushButton* button :
             {refreshButton_,
              discoverButton_,
              openButton_,
              letterButton_,
              modeButton_,
              policyButton_,
              unmountButton_,
              copyButton_}) {
            button->setEnabled(!busy);
        }
        if (busy) {
            QApplication::setOverrideCursor(Qt::WaitCursor);
        } else {
            QApplication::restoreOverrideCursor();
        }
    }

    void refreshHealth() {
        setBusy(true);
        int exitCode = 0;
        health_ = runServiceCommand({QStringLiteral("--health")}, &exitCode);
        detail_->setPlainText(compactJson(health_));
        populateMounts();
        statusBar()->showMessage(exitCode == 0 ? QStringLiteral("Health refreshed")
                                               : QStringLiteral("Health check failed"),
                                 5000);
        setBusy(false);
        updateButtonState();
    }

    void populateMounts() {
        table_->setRowCount(0);
        const QJsonArray mounts = health_.value(QStringLiteral("mounts")).toArray();
        table_->setRowCount(mounts.size());
        for (int row = 0; row < mounts.size(); ++row) {
            const QJsonObject mount = mounts.at(row).toObject();
            const bool exists = mount.value(QStringLiteral("exists")).toBool(false);
            const bool enabled = mount.value(QStringLiteral("enabled")).toBool(true);
            const QString state = !enabled ? QStringLiteral("Disabled")
                                           : (exists ? QStringLiteral("Mounted")
                                                     : QStringLiteral("Unavailable"));
            const QStringList values{mount.value(QStringLiteral("mount")).toString(),
                                     mount.value(QStringLiteral("target")).toString(),
                                     modeText(mount),
                                     state,
                                     entryText(mount)};
            for (int col = 0; col < values.size(); ++col) {
                auto* item = new QTableWidgetItem(values.at(col));
                item->setToolTip(values.at(col));
                if (col == 3 && (!exists || !enabled)) {
                    item->setForeground(QBrush(Qt::darkRed));
                }
                table_->setItem(row, col, item);
            }
        }
        if (mounts.size() > 0 && table_->currentRow() < 0) {
            table_->selectRow(0);
        }
    }

    void runDiscovery() {
        setBusy(true);
        int exitCode = 0;
        const QJsonObject discovery =
            runServiceCommand({QStringLiteral("--configure-discovered"),
                               QStringLiteral("--max-physical-drives"),
                               QStringLiteral("32")},
                              &exitCode);
        statusBar()->showMessage(exitCode == 0 ? QStringLiteral("Discovery complete")
                                               : QStringLiteral("Discovery failed"),
                                 5000);
        setBusy(false);
        if (exitCode != 0) {
            QMessageBox::warning(this,
                                 QStringLiteral("Discovery Failed"),
                                 discovery.value(QStringLiteral("stderr")).toString(
                                     QStringLiteral("APFS discovery did not complete.")));
        }
        refreshHealth();
    }

    void openSelectedMount() {
        const QJsonObject mount = selectedMount();
        const QString root = mount.value(QStringLiteral("root")).toString();
        if (root.isEmpty() || !mount.value(QStringLiteral("exists")).toBool(false)) {
            QMessageBox::information(this,
                                     QStringLiteral("Mount Unavailable"),
                                     QStringLiteral("Selected APFS mount is not available."));
            return;
        }
        QDesktopServices::openUrl(QUrl::fromLocalFile(root));
    }

    void unmountSelectedMount() {
        const QJsonObject mount = selectedMount();
        const QString target = mount.value(QStringLiteral("target")).toString();
        const QString mountName = mount.value(QStringLiteral("mount")).toString();
        if (target.isEmpty()) {
            return;
        }
        const QMessageBox::StandardButton answer =
            QMessageBox::question(this,
                                  QStringLiteral("Unmount APFS Volume"),
                                  QStringLiteral("Unmount %1 from %2?")
                                      .arg(mountName, target),
                                  QMessageBox::Yes | QMessageBox::No,
                                  QMessageBox::No);
        if (answer != QMessageBox::Yes) {
            return;
        }

        setBusy(true);
        int exitCode = 0;
        const QJsonObject result = runServiceCommand({QStringLiteral("--remove-mount"),
                                                      QStringLiteral("--target"),
                                                      target},
                                                     &exitCode);
        setBusy(false);
        if (exitCode != 0 || !result.value(QStringLiteral("removed")).toBool(false)) {
            QMessageBox::warning(this,
                                 QStringLiteral("Unmount Failed"),
                                 result.value(QStringLiteral("stderr")).toString(
                                     QStringLiteral("APFS mount was not removed.")));
        } else {
            statusBar()->showMessage(QStringLiteral("Unmount requested"), 5000);
        }
        refreshHealth();
    }

    QString normalizedDriveLetter(const QString& value) const {
        QString mount = value.trimmed().toUpper();
        if (mount.size() == 1 && mount.at(0).isLetter()) {
            mount.append(QLatin1Char(':'));
        }
        if (mount.size() == 2 && mount.at(0).isLetter() && mount.at(1) == QLatin1Char(':')) {
            return mount;
        }
        return {};
    }

    void changeSelectedMountLetter() {
        const QJsonObject mount = selectedMount();
        const QString target = mount.value(QStringLiteral("target")).toString();
        const QString currentMount = mount.value(QStringLiteral("mount")).toString();
        if (target.isEmpty()) {
            return;
        }

        bool ok = false;
        const QString requested =
            QInputDialog::getText(this,
                                  QStringLiteral("Change Drive Letter"),
                                  QStringLiteral("Drive letter for %1").arg(target),
                                  QLineEdit::Normal,
                                  currentMount,
                                  &ok);
        if (!ok) {
            return;
        }
        const QString nextMount = normalizedDriveLetter(requested);
        if (nextMount.isEmpty()) {
            QMessageBox::warning(this,
                                 QStringLiteral("Invalid Drive Letter"),
                                 QStringLiteral("Enter a drive letter such as X:."));
            return;
        }

        setBusy(true);
        int exitCode = 0;
        const QJsonObject result = runServiceCommand({QStringLiteral("--set-mount"),
                                                      QStringLiteral("--target"),
                                                      target,
                                                      QStringLiteral("--mount"),
                                                      nextMount},
                                                     &exitCode);
        setBusy(false);
        if (exitCode != 0) {
            QMessageBox::warning(this,
                                 QStringLiteral("Drive Letter Failed"),
                                 result.value(QStringLiteral("stderr")).toString(
                                     QStringLiteral("Drive letter was not changed.")));
        } else {
            statusBar()->showMessage(QStringLiteral("Drive letter updated"), 5000);
        }
        refreshHealth();
    }

    void changeSelectedMountMode() {
        const QJsonObject mount = selectedMount();
        const QString target = mount.value(QStringLiteral("target")).toString();
        const QString mountName = mount.value(QStringLiteral("mount")).toString();
        const bool readOnly = mount.value(QStringLiteral("read_only")).toBool(true);
        const bool rawWrites = mount.value(QStringLiteral("allow_raw_writes")).toBool(false);
        if (target.isEmpty()) {
            return;
        }

        const QString nextMode = readOnly ? QStringLiteral("read/write") : QStringLiteral("read-only");
        const QString detail = readOnly
            ? QStringLiteral("Enable read/write mode for %1 (%2)? Raw physical APFS volumes still require elevated raw-write proof.")
                  .arg(mountName, target)
            : QStringLiteral("Return %1 (%2) to read-only mode?").arg(mountName, target);
        const QMessageBox::StandardButton answer =
            QMessageBox::question(this,
                                  QStringLiteral("Change APFS Mode"),
                                  detail,
                                  QMessageBox::Yes | QMessageBox::No,
                                  QMessageBox::No);
        if (answer != QMessageBox::Yes) {
            return;
        }

        QStringList args{QStringLiteral("--set-policy"), QStringLiteral("--target"), target};
        args.append(readOnly ? QStringLiteral("--read-write") : QStringLiteral("--read-only"));
        if (rawWrites && !readOnly) {
            args.append(QStringLiteral("--allow-raw-writes"));
        }
        setBusy(true);
        int exitCode = 0;
        const QJsonObject result = runServiceCommand(args, &exitCode);
        setBusy(false);
        if (exitCode != 0) {
            QMessageBox::warning(this,
                                 QStringLiteral("APFS Mode Failed"),
                                 result.value(QStringLiteral("stderr")).toString(
                                     QStringLiteral("APFS mode was not changed.")));
        } else {
            statusBar()->showMessage(QStringLiteral("APFS mode changed to %1").arg(nextMode),
                                     5000);
        }
        refreshHealth();
    }

    void changeSelectedMountPolicy() {
        const QJsonObject mount = selectedMount();
        const QString target = mount.value(QStringLiteral("target")).toString();
        const QString mountName = mount.value(QStringLiteral("mount")).toString();
        const bool enabled = mount.value(QStringLiteral("enabled")).toBool(true);
        if (target.isEmpty()) {
            return;
        }

        const QString action = enabled ? QStringLiteral("Disable") : QStringLiteral("Enable");
        const QMessageBox::StandardButton answer =
            QMessageBox::question(this,
                                  QStringLiteral("%1 APFS Automount").arg(action),
                                  QStringLiteral("%1 automount for %2 (%3)?")
                                      .arg(action, mountName, target),
                                  QMessageBox::Yes | QMessageBox::No,
                                  QMessageBox::No);
        if (answer != QMessageBox::Yes) {
            return;
        }

        setBusy(true);
        int exitCode = 0;
        const QJsonObject result = runServiceCommand({QStringLiteral("--set-enabled"),
                                                      QStringLiteral("--target"),
                                                      target,
                                                      QStringLiteral("--enabled"),
                                                      enabled ? QStringLiteral("false")
                                                              : QStringLiteral("true")},
                                                     &exitCode);
        setBusy(false);
        if (exitCode != 0) {
            QMessageBox::warning(this,
                                 QStringLiteral("Automount Policy Failed"),
                                 result.value(QStringLiteral("stderr")).toString(
                                     QStringLiteral("Automount policy was not changed.")));
        } else {
            statusBar()->showMessage(QStringLiteral("Automount policy updated"), 5000);
        }
        refreshHealth();
    }

    void copyHealthJson() {
        QApplication::clipboard()->setText(compactJson(health_));
        statusBar()->showMessage(QStringLiteral("JSON copied"), 3000);
    }

    void updateButtonState() {
        const QJsonObject mount = selectedMount();
        const bool hasMount = !mount.isEmpty();
        openButton_->setEnabled(hasMount && mount.value(QStringLiteral("exists")).toBool(false));
        letterButton_->setEnabled(hasMount);
        modeButton_->setEnabled(hasMount);
        modeButton_->setText(mount.value(QStringLiteral("read_only")).toBool(true)
                                 ? QStringLiteral("RW")
                                 : QStringLiteral("RO"));
        policyButton_->setEnabled(hasMount);
        policyButton_->setText(mount.value(QStringLiteral("enabled")).toBool(true)
                                   ? QStringLiteral("Disable")
                                   : QStringLiteral("Enable"));
        unmountButton_->setEnabled(hasMount);
        copyButton_->setEnabled(!health_.isEmpty());
    }

    QSplitter* splitter_{nullptr};
    QTableWidget* table_{nullptr};
    QPlainTextEdit* detail_{nullptr};
    QPushButton* refreshButton_{nullptr};
    QPushButton* discoverButton_{nullptr};
    QPushButton* openButton_{nullptr};
    QPushButton* letterButton_{nullptr};
    QPushButton* modeButton_{nullptr};
    QPushButton* policyButton_{nullptr};
    QPushButton* unmountButton_{nullptr};
    QPushButton* copyButton_{nullptr};
    QJsonObject health_;
    bool busy_{false};
};

}  // namespace

int main(int argc, char* argv[]) {
    QStringList rawArgs;
    for (int i = 0; i < argc; ++i) {
        rawArgs.append(QString::fromLocal8Bit(argv[i]));
    }
    if (rawArgs.contains(QStringLiteral("--status"), Qt::CaseInsensitive)) {
        QCoreApplication app(argc, argv);
        int exitCode = 0;
        const QJsonObject health = runServiceCommand({QStringLiteral("--health")}, &exitCode);
        printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_manager")},
                   {QStringLiteral("ui"), QStringLiteral("available")},
                   {QStringLiteral("service_exe"), serviceExePath()},
                   {QStringLiteral("health"), health}});
        return exitCode == 0 ? 0 : 1;
    }

    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("APFS for Windows"));
    QApplication::setApplicationDisplayName(QStringLiteral("APFS for Windows"));
    QApplication::setOrganizationName(QStringLiteral("APFS for Windows"));
    QApplication::setQuitOnLastWindowClosed(false);
    const QIcon icon = stackedApfsIcon();
    QApplication::setWindowIcon(icon);

    MountManagerWindow window;
    window.setWindowIcon(icon);
    QMenu trayMenu;
    QAction openAction(QStringLiteral("Open"), &trayMenu);
    QAction exitAction(QStringLiteral("Exit"), &trayMenu);
    trayMenu.addAction(&openAction);
    trayMenu.addSeparator();
    trayMenu.addAction(&exitAction);
    if (rawArgs.contains(QStringLiteral("--self-test"), Qt::CaseInsensitive)) {
        const QJsonObject result = window.selfTestResult(icon, trayMenu);
        printJson(result);
        return result.value(QStringLiteral("health_ok")).toBool(false) ? 0 : 1;
    }

    QLocalSocket existingInstance;
    existingInstance.connectToServer(QString::fromLatin1(kManagerInstanceServer));
    if (existingInstance.waitForConnected(1000)) {
        existingInstance.write(
            rawArgs.contains(QStringLiteral("--tray"), Qt::CaseInsensitive) ? "ping" : "show");
        existingInstance.flush();
        existingInstance.waitForBytesWritten(1000);
        return 0;
    }

    QLocalServer instanceServer;
    if (!instanceServer.listen(QString::fromLatin1(kManagerInstanceServer))) {
        QLocalServer::removeServer(QString::fromLatin1(kManagerInstanceServer));
        if (!instanceServer.listen(QString::fromLatin1(kManagerInstanceServer))) {
            QMessageBox::critical(nullptr,
                                  QStringLiteral("APFS for Windows"),
                                  QStringLiteral("Unable to start the mount manager instance."));
            return 1;
        }
    }
    QObject::connect(&instanceServer, &QLocalServer::newConnection, [&instanceServer, &window]() {
        while (instanceServer.hasPendingConnections()) {
            QLocalSocket* socket = instanceServer.nextPendingConnection();
            if (socket->bytesAvailable() == 0) {
                socket->waitForReadyRead(250);
            }
            const QByteArray command = socket->readAll().trimmed();
            socket->disconnectFromServer();
            socket->deleteLater();
            if (command != QByteArrayLiteral("show")) {
                continue;
            }
            window.showNormal();
            window.raise();
            window.activateWindow();
        }
    });

    QSystemTrayIcon trayIcon(icon);
    trayIcon.setToolTip(QStringLiteral("APFS for Windows"));
    trayIcon.setContextMenu(&trayMenu);

    QObject::connect(&openAction, &QAction::triggered, [&window]() {
        window.showNormal();
        window.raise();
        window.activateWindow();
    });
    QObject::connect(&exitAction, &QAction::triggered, [&trayIcon, &app]() {
        trayIcon.hide();
        app.quit();
    });
    QObject::connect(&trayIcon,
                     &QSystemTrayIcon::activated,
                     [&window](QSystemTrayIcon::ActivationReason reason) {
                         if (reason == QSystemTrayIcon::Trigger ||
                             reason == QSystemTrayIcon::DoubleClick) {
                             window.showNormal();
                             window.raise();
                             window.activateWindow();
                         }
                     });
    trayIcon.show();

    if (!rawArgs.contains(QStringLiteral("--tray"), Qt::CaseInsensitive)) {
        window.show();
    }
    return app.exec();
}
