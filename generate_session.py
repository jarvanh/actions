import os
import sys

try:
    from telethon.sync import TelegramClient
    from telethon.sessions import StringSession
except ImportError:
    print("Telethon library not found. Please install it first by running:")
    print("pip install telethon")
    sys.exit(1)

print("="*60)
print("Telegram Userbot Session Generator")
print("="*60)
print("You can get your API ID and API HASH by creating an application")
print("at https://my.telegram.org/apps")
print("-"*60)

API_ID = input("Please enter your API ID (e.g. 1234567): ").strip()
API_HASH = input("Please enter your API HASH: ").strip()

if not API_ID or not API_HASH:
    print("Error: API ID and API HASH cannot be empty.")
    sys.exit(1)

try:
    API_ID = int(API_ID)
except ValueError:
    print("Error: API ID must be a number.")
    sys.exit(1)

print("\nLogging in... (You may be asked for phone number and auth code)")
with TelegramClient(StringSession(), API_ID, API_HASH) as client:
    session_string = client.session.save()
    
    print("\n" + "="*60)
    print("SUCCESS! Here is your Session String:")
    print("="*60)
    print(session_string)
    print("="*60)
    print("IMPORTANT: Treat this string like your password!")
    print("Go to your GitHub repository: Settings -> Secrets and variables -> Actions")
    print("Add a new Repository secret named 'TG_SESSION_STRING' and paste the string above.")
    print("Also add 'TG_API_ID' and 'TG_API_HASH' as secrets.")
    print("="*60)
