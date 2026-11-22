import SwiftUI

struct ServerView: View {
    @Environment(AppModel.self) private var app
    @State private var address = Persist.defaults.string(forKey: "hm-last-address") ?? ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                AppMark().frame(width: 96, height: 96)
                VStack(spacing: 8) {
                    Text("HomeMusic").font(.largeTitle.weight(.bold))
                    Text("Ваша музыка с вашего ПК").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Адрес сервера").font(.headline)
                    TextField("192.168.1.10 или music-pc.local", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.continue)
                        .onSubmit(next)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if let url = AppModel.normalize(address) {
                        Text("Хаб: \(url.absoluteString)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Телефон и ПК должны быть в одной сети (или связаны вашим VPN). IP ПК покажет команда ipconfig.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Button(action: next) {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text("Далее").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .prominentButton()
                .disabled(busy || AppModel.normalize(address) == nil)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = address.isEmpty }
    }

    private func next() {
        guard !busy else { return }
        busy = true
        error = nil
        Persist.defaults.set(address, forKey: "hm-last-address")
        Task {
            error = await app.chooseServer(address)
            busy = false
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var registering = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 30)
                AppMark().frame(width: 76, height: 76)
                VStack(spacing: 6) {
                    Text(registering ? "Регистрация" : "Вход").font(.largeTitle.weight(.bold))
                    Text(app.serverURL?.host() ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    if registering {
                        field("Код приглашения", text: $code).textInputAutocapitalization(.characters)
                    }
                    field(registering ? "Имя пользователя" : "Логин или почта", text: $username)
                        .textContentType(.username)
                    SecureField("Пароль", text: $password)
                        .textContentType(registering ? .newPassword : .password)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .submitLabel(.go)
                        .onSubmit(submit)
                    Text("Логин и пароль — учётная запись вашего Navidrome.").font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                }
                Button(action: submit) {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(registering ? "Создать аккаунт" : "Войти").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .prominentButton()
                .disabled(busy || username.isEmpty || password.isEmpty || (registering && code.isEmpty))
                if app.authOptions?.invites == true {
                    Button(registering ? "У меня есть аккаунт" : "Есть приглашение? Зарегистрироваться") {
                        registering.toggle(); error = nil
                    }
                    .font(.subheadline)
                }
                Button("Другой сервер") { app.changeServer() }.font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { if app.authOptions == nil { app.authOptions = try? await HubClient.shared.authOptions() } }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func submit() {
        guard !busy, !username.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        Task {
            error = registering ? await app.register(code: code, username: username, password: password)
                                : await app.login(username: username, password: password)
            busy = false
        }
    }
}

/// The app's mark: a glassy disc with a note.
struct AppMark: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.27, blue: 0.4), Color(red: 0.62, green: 0.18, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note.house.fill").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
        }
        .shadow(color: .pink.opacity(0.35), radius: 20, y: 10)
    }
}
