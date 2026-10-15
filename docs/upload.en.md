# Uploading this repository to GitHub

[English](upload.en.md) · [한국어](upload.ko.md) · [README](../README.md)

Extract the prepared ZIP first. Upload the **contents** of `r8q-debian-github` so that `README.md`, `docs`, `patches`, `sources`, and `templates` are at the repository root. Uploading only the ZIP file will not make GitHub display the documentation as a project.

## Browser upload

1. Create a repository in your GitHub account. For a clean first import, leave the generated README, license, and gitignore options empty.
2. Open the repository's file upload page. In an existing repository, choose **Add file → Upload files**.
3. Drag in the extracted files and directories. Check that the preview puts `README.md` at the root and keeps the directory structure.
4. Review the changes and commit them using the repository's normal workflow.

Browser file pickers may hide `.gitignore` and `.gitattributes`. Add those two files separately if they are omitted, or use Git for the import. Keep the supplied patch and C source files unchanged so their checksums remain valid. GitHub documents browser and command-line uploads in [Adding a file to a repository](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository).

## Git upload to a new empty repository

Run these commands **inside the extracted `r8q-debian-github` directory**. Replace the URL with the URL of your own empty GitHub repository. The commands below are instructions for the repository owner; preparing this package does not execute them.

```sh
git init -b main
git add .
git status --short
git diff --cached --stat
git commit -m "Document the r8q Debian native port"
git remote add origin https://github.com/YOUR-USERNAME/YOUR-REPOSITORY.git
git push -u origin main
```

Use your existing Git authentication. If the remote already has commits, clone it first, copy these files into that checkout, review the changes, and commit on the appropriate branch. Do not force-push over an existing history for this import.

## After upload

- Check the English README and its Korean language link.
- Open both complete porting guides and verify their relative links.
- Keep boot dumps, firmware, rootfs archives, personal keys, and build output out of the repository. The supplied `.gitignore` excludes common local artifacts.
- `SHA256SUMS` describes this prepared snapshot. Regenerate it when you intentionally change tracked files.
