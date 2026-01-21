# API Keys Configuration

This project uses Google Gemini API for AI features. Here's how to configure your API keys.

## Quick Setup

1. Get an API key from [Google AI Studio](https://makersuite.google.com/app/apikey)
2. Copy the template:
   ```bash
   cp MarginShot.xcodeproj/Secrets.xcconfig.template MarginShot.xcodeproj/Secrets.xcconfig
   ```
3. Edit `Secrets.xcconfig` with your API key

## How It Works

The app reads the `GEMINI_API_KEY` build setting, which can come from two sources:

| Priority | Source | Description |
|----------|--------|-------------|
| 1st | Environment variable `GEMINI_API_KEY` | If set in your shell, takes precedence |
| 2nd | `Secrets.xcconfig` | Fallback when env var is not set |

### Using Environment Variables (Optional)

For local development, you can set the key in your shell profile (`~/.zshrc`):

```bash
export GEMINI_API_KEY=your_api_key_here
```

**To use the xcconfig value instead**, unset the env var:
```bash
unset GEMINI_API_KEY
```

## Security Notes

- `Secrets.xcconfig` is **gitignored** - never commit it
- `Secrets.xcconfig.template` is tracked - use it as a reference
- The exposed key was rotated and removed from git history

## Adding New Secrets

1. Add to `Secrets.xcconfig` and `Secrets.xcconfig.template`
2. Reference in code with `$(YOUR_VARIABLE_NAME)` in Info.plist
3. Or use `Bundle.main.object(forInfoDictionaryKey:)` in Swift code
