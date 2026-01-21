# Build Configuration Setup

MarginShot uses build configuration files to manage sensitive values like OAuth credentials. This keeps actual credentials out of version control. The project uses `MarginShot.xcodeproj/Configuration.xcconfig.template` as the base config and optionally includes `MarginShot.xcodeproj/Configuration.xcconfig` for local overrides.

## Quick Setup

1. (Optional) Copy the template to create your local configuration:
   ```bash
   cp MarginShot.xcodeproj/Configuration.xcconfig.template MarginShot.xcodeproj/Configuration.xcconfig
   ```

2. Edit `MarginShot.xcodeproj/Configuration.xcconfig` and replace placeholder values with your actual credentials.

3. Alternatively, pass build settings via environment variables when building:
   ```bash
   GITHUB_CLIENT_ID=your_actual_client_id_here \
     GITHUB_REDIRECT_URI=marginshot://github-auth \
     xcodebuild -scheme MarginShot -configuration Debug
   ```

## GitHub OAuth Setup

To enable GitHub sync, you need to create a GitHub OAuth App:

1. Go to https://github.com/settings/developers
2. Click "New OAuth App"
3. Fill in the form:
   - **Application name**: MarginShot (or your preferred name)
   - **Homepage URL**: `http://localhost` (or any URL - this is a native app)
   - **Authorization callback URL**: `marginshot://github-auth`
4. Click "Register application"
5. Copy the **Client ID** and paste it into `Configuration.xcconfig` (or provide it via `xcodebuild` settings):
   ```
   GITHUB_CLIENT_ID = your_actual_client_id_here
   ```

The redirect URI is already set to `marginshot://github-auth` in the configuration, which matches the URL scheme registered in the app.

## Configuration Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GITHUB_CLIENT_ID` | Yes | - | Your GitHub OAuth App client ID |
| `GITHUB_REDIRECT_URI` | No | `marginshot://github-auth` | OAuth callback URL scheme |
| `GEMINI_API_KEY` | No | - | Google Gemini API key (can also be set in app Settings) |

## Security Notes

- `Configuration.xcconfig` is listed in `.gitignore` and will not be committed to version control
- The `Configuration.xcconfig.template` file is kept in version control as a reference and base config
- Never commit actual credentials to the repository

## Troubleshooting

**GitHub sign-in reports a missing client ID:**
- Make sure you've created `Configuration.xcconfig` (not just the template) or passed `GITHUB_CLIENT_ID` to `xcodebuild`
- Verify the variable is set and not commented out
- Clean the build folder (Product > Clean Build Folder) and rebuild

**GitHub sign-in fails:**
- Verify your Client ID is correct in Configuration.xcconfig
- Ensure the Authorization callback URL in your GitHub OAuth App settings matches `marginshot://github-auth`
