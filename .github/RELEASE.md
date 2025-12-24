# Release Process

This repository uses [release-please](https://github.com/googleapis/release-please) to automate releases based on [Conventional Commits](https://www.conventionalcommits.org/).

## How It Works

When you push commits to the `main` branch, the release-please workflow:

1. **Analyzes commits** since the last release
2. **Determines the next version** based on commit types
3. **Creates or updates a release PR** with:
   - Updated CHANGELOG.md
   - Updated version in mix.exs
   - A summary of changes

4. When the release PR is merged:
   - A GitHub release is created
   - The package is published to Hex.pm

## Commit Types and Versioning

Since this project is pre-1.0.0, the configuration uses special versioning rules:

### Current Behavior (version < 1.0.0)

With `bump-minor-pre-major` and `bump-patch-for-minor-pre-major` enabled:

- **`feat:`** - Feature additions → **Minor version bump** (0.x.0)
- **`fix:`** - Bug fixes → **Patch version bump** (0.0.x)
- **`chore:`** - Maintenance tasks → **Patch version bump** (0.0.x)
- **`docs:`** - Documentation → **Patch version bump** (0.0.x)
- **`refactor:`** - Code refactoring → **Patch version bump** (0.0.x)
- **`test:`** - Test updates → **Patch version bump** (0.0.x)
- **`build:`** - Build system → **Patch version bump** (0.0.x)
- **`ci:`** - CI/CD changes → **Patch version bump** (0.0.x)
- **`perf:`** - Performance → **Patch version bump** (0.0.x)
- **`revert:`** - Reverts → **Patch version bump** (0.0.x)

### Future Behavior (version >= 1.0.0)

Once the project reaches 1.0.0, standard semantic versioning will apply:

- **`feat:`** - Minor bump (x.1.0)
- **`fix:`** - Patch bump (x.0.1)
- **`perf:`** - Patch bump (x.0.1)
- **Others** (`chore:`, `docs:`, etc.) - **No version bump** (won't trigger a release)

**Note:** This is the standard semantic versioning behavior that will only apply after version 1.0.0 is reached.

## Commit Message Format

Follow the Conventional Commits specification:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Examples

```
feat: add support for PDF document ingestion

fix: correct similarity score calculation

chore: upgrade dependencies to latest versions

docs: update installation instructions

refactor: simplify chunking logic
```

### Breaking Changes

To indicate a breaking change (major version bump), add `!` after the type or include `BREAKING CHANGE:` in the footer:

```
feat!: redesign public API

BREAKING CHANGE: The `search` function now returns a list of maps instead of tuples
```

## Configuration

Release-please configuration is stored in two files:

- **`release-please-config.json`** - Main configuration
- **`.release-please-manifest.json`** - Current version tracking

### Key Configuration Options

The release-please-config.json contains:

- **`bump-minor-pre-major: true`** - Feature commits bump minor version even for 0.x versions
- **`bump-patch-for-minor-pre-major: true`** - All conventional commits bump patch for 0.x versions
- **`changelog-sections: [...]`** - Organizes changelog by commit type

## Manual Release

If you need to force a specific version, you can:

1. Add a commit with the version in the footer:
   ```
   chore: prepare release

   Release-As: 1.0.0
   ```

2. Or manually edit `.release-please-manifest.json` and merge to main

## Troubleshooting

### Release PR Not Created

- Ensure commits follow Conventional Commits format
- Check that commits are on the `main` branch
- Verify the workflow ran successfully in the Actions tab

### Version Not Bumping

- Pre-1.0.0: All valid conventional commits should bump the version
- Post-1.0.0: Only `feat:`, `fix:`, and `perf:` bump versions by default

### CI/CD Issues

Check the workflow logs at: https://github.com/georgeguimaraes/arcana/actions/workflows/release-please.yml

## References

- [Release Please Documentation](https://github.com/googleapis/release-please)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Semantic Versioning](https://semver.org/)
