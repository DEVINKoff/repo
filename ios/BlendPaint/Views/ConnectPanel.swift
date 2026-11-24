import SwiftUI

struct ConnectPanel: View {
    @Bindable var model: AppModel
    @FocusState var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Blender").font(.title3.bold())
                Spacer()
                statusBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("IP компьютера").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("192.168.1.137", text: $model.manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { model.connect(model.manualHost) }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
                    Button("Подключить") { model.connect(model.manualHost) }
                        .buttonStyle(.glassProminent)
                }
                Text("Порт по умолчанию 47800. Можно указать как IP:порт.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Text("В локальной сети").font(.headline)
                Spacer()
                Button {
                    model.scan()
                } label: {
                    if model.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Найти", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.scanning)
            }

            ScrollView {
                VStack(spacing: 8) {
                    if model.hosts.isEmpty {
                        Text(model.scanning ? "Ищу Blender в сети…" : "Нажми «Найти». При первом запуске iOS спросит разрешение на доступ к локальной сети — разреши и повтори поиск.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.hosts) { h in
                        Button {
                            model.connect(h.ip)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(h.ip).font(.body.monospaced())
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Toggle("Автоподключение", isOn: $model.settings.autoConnect)

            if model.connection != .disconnected {
                Button(role: .destructive) {
                    model.disconnect()
                } label: {
                    Label("Отключиться", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.connection {
        case .connected(let h):
            Label(h, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .connecting:
            Label("Подключение…", systemImage: "hourglass").foregroundStyle(.yellow).font(.caption)
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).lineLimit(2)
        case .disconnected:
            Label("Нет связи", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        }
    }
}

struct SettingsPanel: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Ввод") {
                    Toggle("Рисовать пальцем", isOn: $model.settings.fingerPainting)
                    Toggle("Показывать контур кисти", isOn: $model.settings.showCursor)
                    Toggle("Боковая панель справа", isOn: $model.settings.sidebarOnRight)
                }
                Section {
                    PressureCurveEditor(curve: $model.settings.pressureCurve)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Сглаживание нажатия")
                            Spacer()
                            Text("\(Int(model.settings.pressureSmoothing * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.pressureSmoothing, in: 0...0.9)
                    }
                } header: {
                    Text("Нажатие и сглаживание")
                } footer: {
                    Text("Как в Procreate: Настройки → Нажатие и сглаживание. Кривая применяется ко всем кистям.")
                }
                Section {
                    Toggle("QuickShape", isOn: $model.settings.quickShape)
                    if model.settings.quickShape {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Задержка удержания")
                                Spacer()
                                Text(String(format: "%.2f с", model.settings.quickShapeDelay)).foregroundStyle(.secondary)
                            }
                            Slider(value: $model.settings.quickShapeDelay, in: 0.25...1.5)
                        }
                    }
                } header: {
                    Text("Жесты")
                } footer: {
                    Text("Закончи штрих и задержи Pencil — линия станет прямой, замкнутый контур — эллипсом.")
                }
                Section("Вьюпорт") {
                    Picker("HDRI", selection: $model.settings.hdri) {
                        ForEach(BlenderHDRI.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Яркость мира")
                            Spacer()
                            Text("\(Int(model.settings.envStrength * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.envStrength, in: 0.2...3)
                    }
                    Toggle("Сетка пола", isOn: $model.settings.showGrid)
                    Toggle("Оси X / Y", isOn: $model.settings.showAxes)
                    Toggle("Навигационный гизмо", isOn: $model.settings.showGizmo)
                }
                Section("3D-рисование") {
                    Toggle("Не красить сквозь меш (окклюзия)", isOn: $model.settings.occlusion)
                    Toggle("Красить обратные стороны", isOn: $model.settings.paintBackfaces)
                    VStack(alignment: .leading) {
                        Text("Смягчение по углу к камере")
                        Slider(value: $model.settings.facingFade, in: 0...0.6)
                    }
                    Toggle("Точный шейдер из нод Blender", isOn: $model.settings.exactShader)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Разрешение 3D-вида")
                            Spacer()
                            Text("\(Int(model.settings.renderScale * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.renderScale, in: 0.5...1, step: 0.05)
                    }
                    Toggle("Упрощённое превью: текстура как Base Color, если не найдена", isOn: $model.settings.paintedAsBase)
                }
                Section("Синхронизация с Blender") {
                    Toggle("Обновлять во время штриха", isOn: $model.settings.liveSync)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Частота отправки")
                            Spacer()
                            Text("\(Int(model.settings.syncFPS)) в сек.").foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.syncFPS, in: 2...30, step: 1)
                    }
                    Toggle("Автосохранение слоёв на iPad", isOn: $model.settings.autosave)
                }
                Section("UV-сетка") {
                    VStack(alignment: .leading) {
                        Text("Яркость сетки")
                        Slider(value: $model.settings.wireOpacity, in: 0.05...1)
                    }
                }
                Section("Обновления") {
                    LabeledContent("Сборка", value: "\(model.updater.currentBuild)")
                    Text("Добавь источник один раз — SideStore/AltStore будут обновлять приложение сами:")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(Updater.sourceURL).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Скопировать URL источника") { UIPasteboard.general.string = Updater.sourceURL }
                    Button("Проверить обновления") { model.updater.dismissed = false; model.updater.check() }
                }
                Section("Жесты") {
                    gesture("hand.tap", "2 пальца — отменить, 3 пальца — повторить")
                    gesture("hand.raised", "4 пальца — скрыть/показать интерфейс")
                    gesture("hand.point.up.left", "Удержание пальцем — пипетка")
                    gesture("arrow.up.and.down.and.arrow.left.and.right", "2D: щипок/поворот/сдвиг двумя пальцами")
                    gesture("rotate.3d", "3D: 1 палец — вращение, 2 — сдвиг и зум")
                    gesture("applepencil.tip", "Двойной тап по Pencil — переключение ластика (как в настройках iPad)")
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }

    private func gesture(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout)
    }
}
