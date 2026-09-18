class FakeCliSource extends ComicSource {
    name = "Fake CLI"
    key = "fake_cli"
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = ""

    _folders = {
        keep: "Keep",
        empty: "Empty",
    }
    _memberships = {
        alpha: ["keep"],
    }

    _comic(id, title) {
        return new Comic({
            id: id,
            title: title,
            subTitle: "Fixture Author",
            cover: `https://example.invalid/${id}.jpg`,
            tags: ["fixture"],
            description: "QuickJS fixture",
            maxPage: 2,
            favoriteId: `favorite-${id}`,
        })
    }

    explore = [
        {
            title: "Paged fixture",
            type: "multiPageComicList",
            load: async (page) => ({
                comics: [this._comic(`explore-${page}`, `Explore ${page}`)],
                maxPage: 2,
            }),
        },
        {
            title: "Mixed fixture",
            type: "mixed",
            load: async (index) => ({
                data: [
                    [this._comic(`mixed-${index}`, `Mixed ${index}`)],
                    {
                        title: "Fixture section",
                        comics: [this._comic(`section-${index}`, `Section ${index}`)],
                        viewMore: null,
                    },
                ],
                maxPage: 2,
            }),
        },
    ]

    category = {
        title: "Fixture categories",
        parts: [
            {
                name: "Kinds",
                type: "fixed",
                categories: [
                    {
                        label: "All",
                        target: {
                            page: "category",
                            attributes: {category: "all", param: null},
                        },
                    },
                ],
            },
        ],
        enableRankingPage: true,
    }

    categoryComics = {
        load: async (category, param, options, page) => ({
            comics: [this._comic(`category-${page}`, `${category} ${options[0]}`)],
            maxPage: 2,
        }),
        optionList: [
            {
                label: "Order",
                options: ["new-New", "old-Old"],
            },
        ],
        ranking: {
            options: ["day-Day", "week-Week"],
            load: async (option, page) => ({
                comics: [this._comic(`ranking-${page}`, `${option} ${page}`)],
                maxPage: 2,
            }),
        },
    }

    search = {
        load: async (keyword, options, page) => ({
            comics: [this._comic(`${keyword}-${page}`, `Result ${page}`)],
            maxPage: 2,
        }),
        optionList: [
            {
                type: "select",
                label: "Sort",
                options: ["new-New", "popular-Popular"],
                default: "new",
            },
        ],
    }

    favorites = {
        multiFolder: true,
        allFavoritesId: "all",
        singleFolderForSingleComic: false,
        loadFolders: async (comicId) => ({
            folders: this._folders,
            favorited: comicId == null ? [] : (this._memberships[comicId] ?? []),
        }),
        addOrDelFavorite: async (comicId, folderId, isAdding, favoriteId) => {
            let memberships = this._memberships[comicId] ?? []
            if (isAdding && !memberships.includes(folderId)) {
                memberships.push(folderId)
            }
            if (!isAdding) {
                memberships = memberships.filter((item) => item !== folderId)
            }
            this._memberships[comicId] = memberships
            return favoriteId ?? "ok"
        },
        loadComics: async (page, folderId) => {
            let ids = Object.keys(this._memberships).filter((id) => {
                let memberships = this._memberships[id]
                return folderId === "all" ? memberships.length > 0 : memberships.includes(folderId)
            })
            return {
                comics: ids.map((id) => this._comic(id, `Favorite ${id}`)),
                maxPage: 1,
            }
        },
        addFolder: async (name) => {
            let id = `folder-${Object.keys(this._folders).length}`
            this._folders[id] = name
            return id
        },
        deleteFolder: async (folderId) => {
            delete this._folders[folderId]
            return "ok"
        },
    }

    comic = {
        loadInfo: async (id) => new ComicDetails({
            title: `Details ${id}`,
            subTitle: "Fixture Author",
            cover: `https://example.invalid/${id}.jpg`,
            description: "QuickJS fixture details",
            tags: {
                Artist: ["Ada"],
                Genre: ["Fixture"],
            },
            chapters: {
                chapter1: "Chapter 1",
                chapter2: "Chapter 2",
            },
            isFavorite: Object.hasOwn(this._memberships, id),
            recommend: [this._comic("related", "Related")],
            commentCount: 7,
            comments: [
                new Comment({
                    userName: "fixture",
                    content: "comment content must not be exposed",
                    id: "comment-1",
                }),
            ],
            maxPage: 2,
        }),
        loadEp: async (comicId, epId) => ({images: []}),
    }
}
