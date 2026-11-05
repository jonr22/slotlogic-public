1. run `xcode-select --install`
2. Put both files in one folder.
3. run `bash build.sh` (The app is built at ~/Applications/MailPrint.app.)
4. To trigger it from Mail, open Automator and make a new Quick Action. Set “Workflow receives” to no input in Mail.app. Add a Run Shell Script action containing open "$HOME/Applications/MailPrint.app", then save it as “Print with Attachments”.
5. To give it a keyboard shortcut, go to System Settings › Keyboard › Keyboard Shortcuts › Services and assign one (for example ⌃⌥⌘P). It will also appear under Mail › Services.

NOTE: The first time you run it, macOS will ask whether MailPrint can control Mail. Click Allow.
