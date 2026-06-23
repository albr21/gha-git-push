# gha-git-push

A GitHub Action to push files or directories to a Git repository.

## Usage

```yaml
steps:
  - name: Push files
    uses: gha-git-push@v1
    with:
      files: |-
        src/file1.txt:dest/file1.txt
        src/file2.txt:dest/file2.txt
        src/dir:dest/dir
      target-repo: owner/repo
      target-branch: main
      commit-message: "Add files"
      commit-author-name: "github-actions[bot]"
      commit-author-email: "github-actions[bot]@users.noreply.github.com"
      auth-method: token
      github-token: ${{ secrets.GITHUB_TOKEN }}
      max-retries: 3
      backoff-base: 5
```

## Contributing

Check out the [CONTRIBUTING](CONTRIBUTING.md) file for guidelines on how to contribute to this project.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
