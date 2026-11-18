# Ultimate Sandbox

A native-style creative toolbox for **Balatro**. Ultimate Sandbox adds any Joker,
consumable, Voucher, or custom playing card directly to a live run, lets you delete any
number of cards from the deck or Jokers from play, and provides an in-game editor for run values.

Everything uses Balatro's own UI, card art, sounds, and animations, so the tools feel like
part of the game.

> Single-player sandbox only. Do not use it to submit fake scores to leaderboards or
> challenge runs.

## Features

- Four compact buttons appear on the right side of a run: `Cards`, `Stats`, `Deck`, and
  `Browse`.
- Browse and spawn every Joker, Tarot, Planet, Spectral card, and Voucher in the game.
- Choose any base-game edition for Jokers and stickers for Jokers only. Tarot, Planet,
  and Spectral cards support only None/Negative editions, matching the base game.
- Create a playing card with any rank, suit, enhancement, edition, and seal, then add it
  to your hand or draw pile.
- Show the entire deck on one screen, select multiple cards, and delete them at once.
- Delete Jokers from play in the same editor, even when they carry an Eternal sticker.
- Edit poker-hand levels, current and future hand/discard counts, hand-size limit, and
  money.

## Requirements

- Balatro (Steam, v1.0.1o) on Windows or macOS
- [Lovely injector](https://github.com/ethangreen-dev/lovely-injector/releases)
- [Steamodded](https://github.com/Steamodded/smods)

## Install

1. Install Lovely and Steamodded as described by their own documentation.
2. Download the latest Ultimate Sandbox release.
3. Extract the `ultimate-sandbox` folder into your Balatro `Mods` folder.
4. Launch the game and start a run. The four Ultimate Sandbox buttons will appear on the
   right side of the screen.

Typical Windows Mods folder:

```text
%AppData%\Balatro\Mods
```

You can also clone the repository:

```bash
git clone https://github.com/wuhan6910/ultimate-balatro-sandbox.git
```

Use either Ultimate Sandbox or the Chinese edition, not both at the same time.

## Usage

### Cards

Choose a rank, suit, enhancement, edition, and seal. Click `Add to Hand` or `Add to Deck`.
Changes apply immediately.

### Stats

Select a poker hand and adjust its level, or choose `All Hands` to change every hand at
once (each hand stops at level 1 when lowering). You can also edit:

- Hands and discards available in the current blind
- Base hands and discards for later blinds
- Hand-size limit
- Money

### Deck

The whole run deck is displayed on one screen. Click cards to select or deselect them,
then click `Delete Selected` to permanently remove all selected cards from every deck area.

Use the `Jokers` tab in the same screen to remove Jokers from play. Deletion bypasses
sell restrictions, so Eternal, Perishable, and Rental stickers cannot block it.

### Browse

Choose a card type, edition, and sticker, then click a card to add it to the run.
Vouchers are redeemed permanently and owned Vouchers are dimmed.

## Compatibility

Built and tested against Balatro **1.0.1o** with Steamodded **1.0.0-beta**. No game files
are modified on disk; remove the mod folder to uninstall completely.

## License and attribution

Ultimate Sandbox is an English edition derived from Balatro Sandbox by Tariq Almheiri and
continued by wuhan6910. The original work and this derivative are distributed under the
MIT License; see [LICENSE](LICENSE).
