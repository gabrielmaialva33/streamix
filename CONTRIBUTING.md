# Contributing to Streamix

Thank you for your interest in contributing to Streamix! This document provides guidelines and information on how to contribute to this project.

## Before You Start

### License

**Important**: Streamix is open-source software licensed under the [MIT License](LICENSE). By contributing, you agree that your contributions will be licensed under the same terms.

### Code of Conduct

We expect all contributors to follow our [Code of Conduct](CODE_OF_CONDUCT.md). Please read it before contributing.

## How to Contribute

### Reporting Bugs

If you have found a bug, please open an issue including:

1. **Clear and descriptive title**
2. **Steps to reproduce** the behavior
3. **Expected behavior** vs. **actual behavior**
4. **Screenshots** (if applicable)
5. **Environment**:
   - Elixir/OTP version
   - Operating System
   - PostgreSQL version
   - Browser (for frontend issues)

### Suggesting Improvements

To suggest an improvement:

1. Check if the suggestion already exists in the issues
2. Open a new issue with the `enhancement` tag
3. Clearly describe the proposed improvement
4. Explain why it would be useful for the project

### Sending Pull Requests

1. **Fork** the repository
2. **Clone** your fork locally
3. **Create a branch** from `master`:
   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b fix/my-bugfix
   ```
4. **Setup the environment**:
   ```bash
   mix setup
   ```
5. **Make your changes** following the project conventions
6. **Run tests**:
   ```bash
   mix test
   ```
7. **Run precommit**:
   ```bash
   mix precommit
   ```
8. **Commit your changes**:
   ```bash
   git commit -m "feat: clear description of the change"
   ```
9. **Push** to your fork:
   ```bash
   git push origin feature/my-feature
   ```
10. Open a **Pull Request**

## Code Conventions

### Code Style

- Follow Elixir and Phoenix conventions
- Use `mix format` to format code
- Use `mix credo --strict` to check quality
- Keep functions small and focused
- Document public functions with `@doc`

### Commit Conventions

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Formatting (does not affect code execution)
- `refactor`: Refactoring
- `perf`: Performance improvement
- `test`: Tests
- `chore`: Maintenance

**Examples**:
```
feat(iptv): add support for M3U8 playlists
fix(auth): resolve session expiration issue
docs(readme): update installation instructions
perf(sync): optimize channel batch insert
```

### Branch Structure

- `master` - Main branch, always stable
- `feature/*` - New features
- `fix/*` - Bug fixes
- `hotfix/*` - Urgent fixes in production

## Development Environment

### Requirements

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 14+
- Node.js 18+ (for assets)
- Redis (optional, for L2 cache)

### Setup

```bash
# Clone the repository
git clone https://github.com/gabrielmaialva33/streamix.git
cd streamix

# Install dependencies and setup the database
mix setup

# Start the development server
mix phx.server
# or with IEx
iex -S mix phx.server
```

### Useful Commands

```bash
# Run tests
mix test
mix test --failed          # Only failed tests
mix test path/to/test.exs  # Specific file

# Quality check
mix format                 # Format code
mix credo --strict         # Static analysis
mix precommit              # Run everything before commit

# Database
mix ecto.migrate           # Run migrations
mix ecto.reset             # Full reset
mix ecto.gen.migration migration_name

# Assets
mix assets.build           # Development build
mix assets.deploy          # Production build
```

## Project Architecture

```
lib/
├── streamix/              # Core business logic
│   ├── accounts/          # Authentication and users
│   ├── iptv/              # Main IPTV functionality
│   │   ├── sync/          # Content synchronization
│   │   ├── gindex/        # Google Drive integration
│   │   └── ...
│   └── workers/           # Background jobs (Oban)
└── streamix_web/          # Web layer (Phoenix)
    ├── components/        # LiveView components
    ├── controllers/       # HTTP controllers
    └── live/              # LiveView pages
```

### Important Conventions

- Use `Req` for HTTP requests (not HTTPoison/Tesla)
- LiveView templates must use `<Layouts.app>`
- Use `<.icon name="hero-*">` for icons
- Use streams for lists in LiveView
- Context functions receive `user_id` or `scope` as the first argument

## Tests

### Writing Tests

- Place tests in `test/` mirroring the `lib/` structure
- Use fixtures and factories when appropriate
- Test success and failure cases
- Keep tests fast and isolated

### Running Tests

```bash
# All tests
mix test

# With coverage
mix test --cover

# Specific tests
mix test test/streamix/iptv_test.exs
mix test test/streamix/iptv_test.exs:42  # Specific line
```

## Questions?

If you have questions about how to contribute:

1. Check existing documentation
2. Search previous issues
3. Open a new issue with the `question` tag

---

Thank you for your contribution to making Streamix better!