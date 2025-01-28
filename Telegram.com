import os
from datetime import datetime
from pymongo import MongoClient
from telegram import Update, KeyboardButton, ReplyKeyboardMarkup
from telegram.ext import Updater, CommandHandler, MessageHandler, Filters, CallbackContext
import openai
from serpapi import GoogleSearch
from dotenv import load_dotenv

# Load environment variables
load_dotenv()
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
MONGODB_URI = os.getenv("MONGODB_URI")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
SERPAPI_KEY = os.getenv("SERPAPI_KEY")

# MongoDB setup
client = MongoClient(MONGODB_URI)
db = client['telegram_bot']
users_collection = db['users']
chat_history_collection = db['chat_history']
file_metadata_collection = db['file_metadata']

# OpenAI setup
openai.api_key = OPENAI_API_KEY

# Start command handler
def start(update: Update, context: CallbackContext):
    chat_id = update.effective_chat.id
    first_name = update.message.chat.first_name
    username = update.message.chat.username

    # Check if user already exists
    if not users_collection.find_one({"chat_id": chat_id}):
        users_collection.insert_one({
            "chat_id": chat_id,
            "first_name": first_name,
            "username": username
        })
        update.message.reply_text("Welcome! You have been registered.")

    # Request phone number
    button = [[KeyboardButton("Share Phone Number", request_contact=True)]]
    reply_markup = ReplyKeyboardMarkup(button, one_time_keyboard=True)
    update.message.reply_text("Please share your phone number:", reply_markup=reply_markup)

# Handle contact sharing
def contact_handler(update: Update, context: CallbackContext):
    contact = update.message.contact
    chat_id = update.effective_chat.id
    if contact:
        users_collection.update_one({"chat_id": chat_id}, {"$set": {"phone_number": contact.phone_number}})
        update.message.reply_text("Phone number saved successfully!")

# Chat handler
def chat_handler(update: Update, context: CallbackContext):
    chat_id = update.effective_chat.id
    user_message = update.message.text

    # Generate response using OpenAI (Gemini API equivalent)
    response = openai.Completion.create(
        model="text-davinci-003",
        prompt=user_message,
        max_tokens=200
    ).choices[0].text.strip()

    # Save chat history in MongoDB
    chat_history_collection.insert_one({
        "chat_id": chat_id,
        "user_message": user_message,
        "bot_response": response,
        "timestamp": datetime.now()
    })

    update.message.reply_text(response)

# Handle file uploads
def file_handler(update: Update, context: CallbackContext):
    file = update.message.document or update.message.photo[-1]
    file_id = file.file_id
    file_name = file.file_name if hasattr(file, 'file_name') else "image.jpg"
    chat_id = update.effective_chat.id

    # Download the file
    file_path = context.bot.get_file(file_id).download(custom_path=file_name)

    # Analyze with OpenAI
    analysis = openai.Image.create(file=open(file_path, "rb"), purpose="describe")["data"]["description"]

    # Save file metadata in MongoDB
    file_metadata_collection.insert_one({
        "chat_id": chat_id,
        "file_name": file_name,
        "description": analysis,
        "timestamp": datetime.now()
    })

    update.message.reply_text(f"File analyzed: {analysis}")

# Web search handler
def web_search(update: Update, context: CallbackContext):
    query = ' '.join(context.args)
    if not query:
        update.message.reply_text("Please provide a search query. Usage: /websearch <query>")
        return

    # Perform web search using SerpAPI
    search = GoogleSearch({"q": query, "api_key": SERPAPI_KEY})
    results = search.get_dict()

    # Extract summary and links
    summary = "\n".join([f"{result['title']}: {result['link']}" for result in results.get('organic_results', [])[:3]])

    update.message.reply_text(f"Search Results:\n{summary}")

# Main function
def main():
    updater = Updater(TELEGRAM_TOKEN)
    dispatcher = updater.dispatcher

    # Command handlers
    dispatcher.add_handler(CommandHandler("start", start))
    dispatcher.add_handler(CommandHandler("websearch", web_search))

    # Message handlers
    dispatcher.add_handler(MessageHandler(Filters.text & ~Filters.command, chat_handler))
    dispatcher.add_handler(MessageHandler(Filters.contact, contact_handler))
    dispatcher.add_handler(MessageHandler(Filters.document | Filters.photo, file_handler))

    # Start polling
    updater.start_polling()
    updater.idle()

if __name__ == "__main__":
    main()
