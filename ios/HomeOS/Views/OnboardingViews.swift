import SwiftUI

/// Glow and title shared by the sign-in and setup screens.
private struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.bottom, 12)
        .background(alignment: .top) {
            GlowView()
                .frame(height: 260)
                .offset(y: -90)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

struct SignInView: View {
    @Environment(FamilyStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var isCreating = false

    var body: some View {
        Form {
            Section {
                OnboardingHeader(title: "homeOS", subtitle: "Your family's calendar, chores and photos — on the wall and in your pocket.")
            }
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(isCreating ? .newPassword : .password)
            } footer: {
                if isCreating { Text("At least 8 characters.") }
            }
            Section {
                Button {
                    Task {
                        if isCreating { await store.signUp(email: email, password: password) }
                        else { await store.signIn(email: email, password: password) }
                    }
                } label: {
                    Text(isCreating ? "Create account" : "Sign in").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill())
                .disabled(email.isEmpty || password.count < 8)
                .listRowBackground(Color.clear)
                Button(isCreating ? "I already have an account" : "New here? Create an account") {
                    withAnimation(Theme.springy) { isCreating.toggle() }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .showsStoreErrors()
    }
}

struct CreateFamilyView: View {
    @Environment(FamilyStore.self) private var store
    @State private var familyName = ""
    @State private var myName = ""

    var body: some View {
        Form {
            Section {
                OnboardingHeader(title: "Welcome", subtitle: "Set up your family. You'll be the first parent.")
            }
            Section("Your family") {
                TextField("Family name (e.g. The Smiths)", text: $familyName)
                TextField("Your name", text: $myName)
            }
            Section {
                Button {
                    Task { await store.createFamily(name: familyName, myName: myName) }
                } label: {
                    Text("Create family").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill())
                .disabled(familyName.isEmpty || myName.isEmpty)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Add kids and pair your wall display next, from the Family tab.")
            }
            Section {
                Button("Sign out") { Task { await store.signOut() } }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .showsStoreErrors()
    }
}
