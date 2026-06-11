import SwiftUI

/// 登录页。PROTOCOL §8.1 —— 两端登录同一账号即建立会合,谁先登无所谓。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("AI Coding Remote")
                .font(.title2.weight(.bold))
            Text("登录后,你的电脑代理会自动出现")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("邮箱", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                appState.login(email: email.isEmpty ? "dev@example.com" : email)
            } label: {
                Text("登录").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(24)
    }
}
