<img width="1116" height="2480" alt="Screenshot_20260630_122907" src="https://github.com/user-attachments/assets/6a4909b4-8018-4b64-8457-eea0be93764b" />
# Book Showcase for KOReader

A KOReader plugin that turns a book’s existing metadata and reading data into a customisable book-card popup.

It is designed for readers who want a clean way to view a book’s cover, rating, completion details, synopsis, review, quote, and reading statistics in one place.

**Version:** 1.1.0

## Features

- Open a showcase from a book’s long-press menu in KOReader Library, File Browser, or History.
- Display the book cover, title, author, series, tags, description, rating, review, favourite quote, and footer.
- Show available KOReader reading data, including:
  - reading progress and status
  - finished date
  - total pages
  - reading time and reading days
  - pages read and reading pace
  - highlights and notes
  - last-opened date
- Built-in templates and saved presets, including a **Finished Book** layout.
- Per-book card profile override, without changing the global design used for other books.
- Long-press an opened showcase to:
  - edit rating
  - edit review
  - edit footer
  - change reading status
  - add or edit a favourite quote
  - change the card profile
  - enter Presentation mode
- Presentation mode for a cleaner full-screen card before taking an Android screenshot.
- Screenshot layouts: **Balanced**, **Cover Focus**, and **Details Focus**.
- Background themes: **Paper**, **Warm Paper**, **Slate**, **Night**, or custom colours.
- Cover controls, including a zoom lock to avoid accidental cover enlargement.
- Optional completion badge: **Finished**, **Reading**, or **On Hold**.
- Optional **Read full description** action for books with longer descriptions.
- Empty sections are hidden automatically when there is no meaningful data to show.
- Global footer, per-book footer, and optional automatic finished-reading footer.
- Backup and restore of plugin settings, colours, and saved presets.

## Screenshots

Add screenshots to a `screenshots` folder in this repository and update the paths below if needed.

| Finished Book showcase | Showcase settings |
| --- | --- |
| `screenshots/finished-book.png` | `screenshots/settings.png` |

## Installation

1. Download or clone this repository.
2. Copy the whole `bookshowcase.koplugin` folder into KOReader’s `plugins` folder.
3. The resulting path must be:

```text
/storage/emulated/0/koreader/plugins/bookshowcase.koplugin/
```

4. Confirm that this folder contains at least:

```text
bookshowcase.koplugin/
├── _meta.lua
└── main.lua
```

5. Fully close and reopen KOReader.
6. Enable **Book Showcase** under KOReader’s Plugin Management screen if it is not already enabled.

Do not place the plugin in your books folder.

## How to use

### Open a book card

1. In Library, File Browser, or History, long-press a book.
2. Select **Open Showcase**.

The plugin uses the currently configured showcase layout, unless that particular book has its own card-profile override.

### Edit the current card

1. Open a showcase.
2. Long-press the opened showcase.
3. Use **Showcase actions** to edit the rating, review, footer, status, or favourite quote.

After a supported edit is saved, the showcase reopens with refreshed content.

### Finished Book card

For a finished book, the Finished Book layout is intended to show:

```text
Title
Author
Rating
Finished date · total pages
Reading time · reading days
About / synopsis
Favourite quote (optional)
My review (optional)
```

Default footers are hidden in this layout unless a custom footer has been set for that book.

### Presentation mode and screenshots

1. Open a showcase.
2. Long-press it.
3. Choose **Presentation mode**.
4. Take an Android screenshot using your device’s normal screenshot shortcut.

On most Android phones, this is **Power + Volume Down**.

The plugin does not directly export PNG files. Native Android screenshots are used because they are more reliable across KOReader Android installations.

## Settings

Open:

```text
KOReader menu → Book Showcase settings
```

Key settings include:

- **Templates & saved presets** — choose a built-in template or save your own setup.
- **Appearance** — background theme, custom colours, popup size, border, alignment, density, completion badge, screenshot layout, and cover controls.
- **Content** — choose which metadata and reading fields appear and set their order.
- **Tools & reset** — preview, backup, restore, reset, and other utility options.

### Background themes

Under **Appearance**, choose one of:

- Paper
- Warm Paper
- Slate
- Night
- Custom colours

Selecting a built-in theme disables custom colours for that showcase style. Select **Custom colours** to return to manual colour choices.

## Notes and limitations

- Reading statistics only appear after KOReader has recorded activity for that book.
- Statistics fields require KOReader’s Reading Statistics plugin to be enabled.
- The plugin reads from KOReader’s stored metadata and statistics; it does **not** modify EPUB, PDF, or other book files.
- Some book metadata may be unavailable depending on the file and how it was imported into KOReader.
- The stable Showcase Actions menu intentionally stays compact on Android. Large dynamic nested action menus may be unstable on some Android devices.

## Version history

### 1.1.0

- Finished Book presentation with title, author, rating, finish date, total pages, synopsis, review, and optional favourite quote.
- Long-press Showcase Actions with safe delayed opening on Android.
- Presentation mode with Balanced, Cover Focus, and Details Focus layouts.
- Paper, Warm Paper, Slate, Night, and custom-colour background options.
- Completion badges, cover zoom lock, and read-full-description support.
- Automatic hiding of empty sections.
- Per-book card-profile override and saved preset support.

### 1.0.0

- Initial Book Showcase release.
| Platform               | Likely compatibility | Notes                                                                                             |
| ---------------------- | -------------------: | ------------------------------------------------------------------------------------------------- |
| Android phones/tablets |         Yes — tested | Your current tested platform.                                                                     |
| Android e-ink devices  |               Likely | Includes Boox, Meebook, Bigme, Likebook, etc., where KOReader runs as an Android app.             |
| Kindle                 |     Likely, untested | KOReader supports Kindle, but installation requires the relevant Kindle jailbreak/launcher setup. |
| Kobo                   |     Likely, untested | KOReader supports Kobo devices through Kobo-specific installation packages.                       |
| PocketBook             |     Likely, untested | KOReader has a PocketBook build.                                                                  |
| reMarkable             |   Possible, untested | KOReader provides reMarkable builds, but the larger screen may need layout adjustments.           |
| Cervantes              |   Possible, untested | KOReader officially supports Cervantes.                                                           |
| Linux desktop          |   Possible, untested | Should load as a plugin, though the showcase is designed mainly for e-ink/touch use.              |
| Ubuntu Touch           |   Possible, untested | KOReader documentation lists Ubuntu Touch support.                                                |

## License

Add your preferred licence here, for example MIT.
