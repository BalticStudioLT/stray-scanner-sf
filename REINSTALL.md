# Reinstalling Stray SF (free Apple ID, every 7 days)

An app signed with a free Apple ID ("Personal Team") stops opening after 7 days. Your scans stay on the
phone as long as you **don't delete the app**; reinstalling over it keeps them.

## Every 7 days

1. Connect the iPhone to the Mac with the cable and unlock it.
2. Open `~/Developer/stray-scanner-sf/StrayScanner.xcworkspace` in Xcode
   (the **.xcworkspace**, not the .xcodeproj).
3. Optional, to get the latest changes: in Terminal
   `cd ~/Developer/stray-scanner-sf && git pull`
4. At the top of the Xcode window, set the scheme to **StrayScanner** and the destination to **your iPhone**.
5. Press **⌘R** (Product ▸ Run). Wait for "Running StrayScanner on …"; the app opens on the phone.
6. Stop with **⌘.** if you like; the app stays installed for another 7 days.

## If something goes wrong

- **"Untrusted Developer" on the phone:** Settings ▸ General ▸ VPN & Device Management ▸ your Apple ID
  under *Developer App* ▸ **Trust**.
- **"Developer Mode required":** Settings ▸ Privacy & Security ▸ Developer Mode ▸ On, restart, confirm.
- **Signing error in Xcode:** click the project ▸ target *StrayScanner* ▸ *Signing & Capabilities* ▸
  check *Automatically manage signing* ▸ Team = *Your Name (Personal Team)*. If the Apple ID was signed out:
  Xcode ▸ Settings ▸ Accounts ▸ add it again.
- **"Maximum number of apps" error:** a free account can have 3 sideloaded apps at once; delete one you don't use.
- **Phone not listed:** unlock it, tap *Trust This Computer*, or re-plug the cable.

## Getting scans to the PC

In the app open the scan ▸ share (zip) ▸ AirDrop/Files, or connect the phone to a computer and copy the
scan folders from the app's *Files* section (Finder ▸ iPhone ▸ Files ▸ Stray SF).
