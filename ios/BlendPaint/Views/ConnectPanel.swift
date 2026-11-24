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
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Кривая нажатия")
                            Spacer()
                            Text(model.settings.pressureGamma < 0.9 ? "мягче" : model.settings.pressureGamma > 1.1 ? "жёстче" : "линейная")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.pressureGamma, in: 0.4...2.5)
                    }
                    Toggle("Показывать контур кисти", isOn: $model.settings.showCursor)
                    Toggle("Боковая панель справа", isOn: $model.settings.sidebarOnRight)
                }
                Section("3D-рисование") {
                    Toggle("Не красить сквозь меш (окклюзия)", isOn: $model.settings.occlusion)
                    Toggle("Красить обратные стороны", isOn: $model.settings.paintBackfaces)
                    VStack(alignment: .leading) {
                        Text("Смягчение по углу к камере")
                        Slider(value: $model.settings.facingFade, in: 0...0.6)
                    }
                    Toggle("Точный шейдер из нод Blender", isOn: $model.settings.exactShader)
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
