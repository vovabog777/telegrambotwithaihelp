import os
import logging
import asyncio
from dotenv import load_dotenv
from telegram import Update, BotCommand
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)
from openai import OpenAI

# Загружаем .env ПЕРВЫМ
load_dotenv("/Users/vladimir/PycharmProjects/PythonProject2/.venv/.env")

TOKEN = os.getenv("TELEGRAM_TOKEN")
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY")
print("TOKEN:", TOKEN)
print("OPENROUTER_API_KEY:", OPENROUTER_API_KEY)

# Клиент OpenRouter ПОСЛЕ load_dotenv
ai_client = OpenAI(
    api_key=OPENROUTER_API_KEY,
    base_url="https://openrouter.ai/api/v1"
)

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO
)


async def ai_reply(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_text = update.message.text
    print(f"Получено сообщение: {user_text}")

    try:
        response = await asyncio.to_thread(
            lambda: ai_client.chat.completions.create(
                model="meta-llama/llama-3.3-70b-instruct:free",
                messages=[{"role": "user", "content": user_text}]
            )
        )
        ai_text = response.choices[0].message.content
        print(f"Ответ AI: {ai_text}")
        await update.message.reply_text(ai_text)  # ← отправляем ответ

    except Exception as e:
        print(f"Ошибка: {e}")
        await update.message.reply_text("Произошла ошибка, попробуй ещё раз.")


async def ai_reply_photo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    prompt = "Пользователь отправил фото. Ответь на это сообщение."

    try:
        response = await asyncio.to_thread(
            lambda: ai_client.chat.completions.create(
                model="meta-llama/llama-3.3-70b-instruct:free",
                messages=[{"role": "user", "content": prompt}]
            )
        )
        ai_text = response.choices[0].message.content
        await update.message.reply_text(ai_text)

    except Exception as e:
        print(f"Ошибка: {e}")
        await update.message.reply_text("Произошла ошибка, попробуй ещё раз.")


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "Привет! Я ваш бот! Напиши что-то, я отвечу искусственным интеллектом."
    )


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Я отвечаю на ваши сообщения и фото с помощью AI!")


async def settings(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Здесь будут настройки профиля.")


async def post_init(application):
    commands = [
        BotCommand("start", "Запустить бота"),
        BotCommand("help", "Показать справку"),
        BotCommand("settings", "Настройки профиля"),
    ]
    await application.bot.set_my_commands(commands)


app = ApplicationBuilder().token(TOKEN).post_init(post_init).build()

app.add_handler(CommandHandler("start", start))
app.add_handler(CommandHandler("help", help_command))
app.add_handler(CommandHandler("settings", settings))
app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, ai_reply))
app.add_handler(MessageHandler(filters.PHOTO, ai_reply_photo))

print("Бот успешно запущен и отвечает через AI...")
app.run_polling()
