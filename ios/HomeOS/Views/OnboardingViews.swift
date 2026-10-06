import SwiftUI

struct SignInView: View {
    @Environment(FamilyStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(isCreating ? .newPassword : .password)
                }
                Section {
                    Button(isCreating ? "Create account" : "Sign in") {
                        Task {
                            if isCreating { await store.signUp(email: email, password: password) }
                            else { await store.signIn(email: email, password: password) }
                        }
                    }
                    .disabled(email.isEmpty || password.count < 8)
                    Button(isCreating ? "I already have an account" : "New here? Create an account") {
                        isCreating.toggle()
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("homeOS")
            .showsStoreErrors()
        }
    }
}

struct CreateFamilyView: View {
    @Environment(FamilyStore.self) private var store
    @State private var familyName = ""
    @State private var myName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Your family") {
                    TextField("Family name (e.g. The Smiths)", text: $familyName)
                    TextField("Your name", text: $myName)
                }
                Section {
                    Button("Create family") {
                        Task { await store.createFamily(name: familyName, myName: myName) }
                    }
                    .disabled(familyName.isEmpty || myName.isEmpty)
                } footer: {
                    Text("You'll be the first parent. Add kids and pair your wall display next.")
                }
            }
            .navigationTitle("Welcome")
            .showsStoreErrors()
        }
    }
}
