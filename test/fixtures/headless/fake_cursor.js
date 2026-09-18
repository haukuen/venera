class FakeCursorSource extends ComicSource {
    name = "Fake Cursor"
    key = "fake_cursor"
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = ""

    search = {
        loadNext: async (keyword, options, next) => {
            UI.showMessage("fixture notice")
            if (keyword === "needs-ui") {
                await UI.showInputDialog("Fixture input")
            }
            if (keyword === "fire-and-forget-ui") {
                UI.showDialog("Fixture dialog", "Interaction required", [])
            }
            return {
                comics: [
                    new Comic({
                        id: next ?? "first",
                        title: keyword,
                        cover: "https://example.invalid/cursor.jpg",
                    }),
                ],
                next: next == null ? "cursor-2" : null,
            }
        },
        optionList: [],
    }

    comic = {
        loadInfo: async (id) => new ComicDetails({
            title: id,
            cover: "https://example.invalid/cursor.jpg",
            tags: {},
            chapters: {},
        }),
        loadEp: async (comicId, epId) => ({images: []}),
    }
}
