import MenuBarShim

print("Stash tests")

T.test("shim ziet MenuBarClientCore") {
    T.expect(STMenuBarShim.isAvailable(),
             "MenuBarClientCore moet laadbaar zijn op macOS 27")
}

T.finish()
