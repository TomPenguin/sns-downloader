import SwiftUI

/// iwara にログインしてトークンを Keychain に保存する。
/// pixiv / Instagram は Cookie が必要なため WKWebView を使うが、iwara は
/// ログイン API がトークンを返すので、そのままフォームで入力させる
struct IwaraLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    var onComplete: (Bool) -> Void

    private enum Field {
        case email
        case password
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }
                } footer: {
                    Text("iwaraのアカウントでログインします。パスワードは保存されず、発行されたトークンだけを端末のKeychainに保存します。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isSubmitting ? "ログイン中…" : "ログイン")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("iwaraにログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        onComplete(false)
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
            .onAppear { focusedField = .email }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                let session = try await IwaraSession.logIn(email: email, password: password)
                session.save()
                // 前のログインで掴んだアクセストークンが残らないようにする
                await IwaraTokenProvider.shared.invalidate()
                isSubmitting = false
                onComplete(true)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
