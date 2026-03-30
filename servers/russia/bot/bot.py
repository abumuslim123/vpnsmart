import asyncio
import functools
import logging
import os
import uuid as uuid_lib

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    BotCommand,
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
)

import db
from config_manager import generate_vless_link, reload_xray_users

BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_ID = int(os.environ["ADMIN_ID"])
RUSSIA_IP = os.environ["RUSSIA_IP"]
REALITY_PUBLIC_KEY = os.environ["REALITY_PUBLIC_KEY"]
REALITY_SHORT_ID = os.environ["REALITY_SHORT_ID"]

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("vpnsmart-bot")

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
router = Router()
dp.include_router(router)


# --- Middleware for admin check ---


def admin_only(handler):
    @functools.wraps(handler)
    async def wrapper(event, **kwargs):
        user_id = None
        if isinstance(event, Message):
            user_id = event.from_user.id
        elif isinstance(event, CallbackQuery):
            user_id = event.from_user.id
        if user_id != ADMIN_ID:
            return
        return await handler(event, **kwargs)
    return wrapper


# --- Keyboards ---


def main_menu_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 Clients", callback_data="menu_list")],
        [InlineKeyboardButton(text="➕ Add client", callback_data="menu_add")],
    ])


def client_kb(name: str):
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🔗 VLESS link", callback_data=f"link_{name}")],
        [InlineKeyboardButton(text="ℹ️ Info", callback_data=f"info_{name}")],
        [InlineKeyboardButton(text="🗑 Delete", callback_data=f"confirmdelete_{name}")],
        [InlineKeyboardButton(text="◀️ Back", callback_data="menu_list")],
    ])


def confirm_delete_kb(name: str):
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="Yes, delete", callback_data=f"delete_{name}"),
            InlineKeyboardButton(text="Cancel", callback_data=f"client_{name}"),
        ],
    ])


def back_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="◀️ Menu", callback_data="menu_main")],
    ])


# --- Commands ---


@router.message(CommandStart())
@admin_only
async def cmd_start(message: Message, **kwargs):
    await message.answer("VPNSmart", reply_markup=main_menu_kb())


@router.message(Command("add"))
@admin_only
async def cmd_add(message: Message, **kwargs):
    parts = message.text.split(maxsplit=2)
    if len(parts) < 2:
        await message.answer("Usage: /add <name> [note]")
        return
    await _add_client(message, parts[1], parts[2] if len(parts) > 2 else "")


@router.message(Command("list"))
@admin_only
async def cmd_list(message: Message, **kwargs):
    await _show_list(message)


@router.message(Command("link"))
@admin_only
async def cmd_link(message: Message, **kwargs):
    parts = message.text.split(maxsplit=1)
    if len(parts) < 2:
        await message.answer("Usage: /link <name>")
        return
    await _show_link(message, parts[1])


@router.message(Command("note"))
@admin_only
async def cmd_note(message: Message, **kwargs):
    parts = message.text.split(maxsplit=2)
    if len(parts) < 3:
        await message.answer("Usage: /note <name> <text>")
        return
    updated = await db.update_note(parts[1], parts[2])
    if updated:
        await message.answer(f"Note updated for '{parts[1]}'.")
    else:
        await message.answer(f"Client '{parts[1]}' not found.")


@router.message(Command("info"))
@admin_only
async def cmd_info(message: Message, **kwargs):
    parts = message.text.split(maxsplit=1)
    if len(parts) < 2:
        await message.answer("Usage: /info <name>")
        return
    await _show_info(message, parts[1])


# --- Callback handlers ---


@router.callback_query(F.data == "menu_main")
@admin_only
async def cb_main_menu(callback: CallbackQuery, **kwargs):
    await callback.message.edit_text("VPNSmart", reply_markup=main_menu_kb())
    await callback.answer()


@router.callback_query(F.data == "menu_list")
@admin_only
async def cb_list(callback: CallbackQuery, **kwargs):
    clients = await db.list_clients()
    if not clients:
        await callback.message.edit_text("No clients.", reply_markup=main_menu_kb())
        await callback.answer()
        return

    buttons = []
    for c in clients:
        label = c["name"]
        if c["note"]:
            label += f" — {c['note'][:30]}"
        buttons.append([InlineKeyboardButton(text=label, callback_data=f"client_{c['name']}")])
    buttons.append([InlineKeyboardButton(text="➕ Add client", callback_data="menu_add")])
    buttons.append([InlineKeyboardButton(text="◀️ Menu", callback_data="menu_main")])

    await callback.message.edit_text(
        f"Clients ({len(clients)}):",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons),
    )
    await callback.answer()


@router.callback_query(F.data == "menu_add")
@admin_only
async def cb_add_prompt(callback: CallbackQuery, **kwargs):
    await callback.message.edit_text(
        "Send command:\n<code>/add name note</code>\n\nExample:\n<code>/add phone-masha Main phone</code>",
        parse_mode="HTML",
        reply_markup=back_kb(),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("client_"))
@admin_only
async def cb_client(callback: CallbackQuery, **kwargs):
    name = callback.data[len("client_"):]
    client = await db.get_client(name)
    if not client:
        await callback.answer("Client not found", show_alert=True)
        return

    note_text = f"\nNote: {client['note']}" if client["note"] else ""
    await callback.message.edit_text(
        f"<b>{client['name']}</b>{note_text}",
        parse_mode="HTML",
        reply_markup=client_kb(name),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("link_"))
@admin_only
async def cb_link(callback: CallbackQuery, **kwargs):
    name = callback.data[len("link_"):]
    client = await db.get_client(name)
    if not client:
        await callback.answer("Client not found", show_alert=True)
        return

    vless = generate_vless_link(
        uuid=client["uuid"],
        name=name,
        server_ip=RUSSIA_IP,
        reality_public_key=REALITY_PUBLIC_KEY,
        short_id=REALITY_SHORT_ID,
    )
    await callback.message.edit_text(
        f"<b>{name}</b>\n\n<code>{vless}</code>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="◀️ Back", callback_data=f"client_{name}")],
        ]),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("info_"))
@admin_only
async def cb_info(callback: CallbackQuery, **kwargs):
    name = callback.data[len("info_"):]
    client = await db.get_client(name)
    if not client:
        await callback.answer("Client not found", show_alert=True)
        return

    vless = generate_vless_link(
        uuid=client["uuid"],
        name=name,
        server_ip=RUSSIA_IP,
        reality_public_key=REALITY_PUBLIC_KEY,
        short_id=REALITY_SHORT_ID,
    )
    await callback.message.edit_text(
        f"Name: <b>{client['name']}</b>\n"
        f"UUID: <code>{client['uuid']}</code>\n"
        f"Note: {client['note'] or '—'}\n"
        f"Created: {client['created_at']}\n\n"
        f"VLESS:\n<code>{vless}</code>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="◀️ Back", callback_data=f"client_{name}")],
        ]),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("confirmdelete_"))
@admin_only
async def cb_confirm_delete(callback: CallbackQuery, **kwargs):
    name = callback.data[len("confirmdelete_"):]
    await callback.message.edit_text(
        f"Delete <b>{name}</b>?",
        parse_mode="HTML",
        reply_markup=confirm_delete_kb(name),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("delete_"))
@admin_only
async def cb_delete(callback: CallbackQuery, **kwargs):
    name = callback.data[len("delete_"):]
    deleted = await db.delete_client(name)
    if not deleted:
        await callback.answer("Client not found", show_alert=True)
        return

    all_clients = await db.get_all_uuids()
    try:
        reload_xray_users(all_clients)
        status = "✅ Xray restarted"
    except Exception as e:
        status = f"⚠️ restart failed: {e}"
        logger.error(f"Failed to reload Xray: {e}")

    await callback.message.edit_text(
        f"Deleted: {name}\n{status}",
        reply_markup=main_menu_kb(),
    )
    await callback.answer()


# --- Helpers ---


async def _add_client(message: Message, name: str, note: str):
    existing = await db.get_client(name)
    if existing:
        await message.answer(f"Client '{name}' already exists.")
        return

    client_uuid = str(uuid_lib.uuid4())
    await db.add_client(name, client_uuid, note)

    all_clients = await db.get_all_uuids()
    try:
        reload_xray_users(all_clients)
        status = "✅ Xray restarted"
    except Exception as e:
        status = f"⚠️ restart failed: {e}"
        logger.error(f"Failed to reload Xray: {e}")

    vless = generate_vless_link(
        uuid=client_uuid,
        name=name,
        server_ip=RUSSIA_IP,
        reality_public_key=REALITY_PUBLIC_KEY,
        short_id=REALITY_SHORT_ID,
    )

    await message.answer(
        f"✅ Added: <b>{name}</b>\n\n"
        f"<code>{vless}</code>\n\n{status}",
        parse_mode="HTML",
        reply_markup=main_menu_kb(),
    )


async def _show_list(message: Message):
    clients = await db.list_clients()
    if not clients:
        await message.answer("No clients.", reply_markup=main_menu_kb())
        return

    buttons = []
    for c in clients:
        label = c["name"]
        if c["note"]:
            label += f" — {c['note'][:30]}"
        buttons.append([InlineKeyboardButton(text=label, callback_data=f"client_{c['name']}")])
    buttons.append([InlineKeyboardButton(text="➕ Add client", callback_data="menu_add")])

    await message.answer(
        f"Clients ({len(clients)}):",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons),
    )


async def _show_link(message: Message, name: str):
    client = await db.get_client(name)
    if not client:
        await message.answer(f"Client '{name}' not found.")
        return

    vless = generate_vless_link(
        uuid=client["uuid"],
        name=name,
        server_ip=RUSSIA_IP,
        reality_public_key=REALITY_PUBLIC_KEY,
        short_id=REALITY_SHORT_ID,
    )
    await message.answer(f"<b>{name}</b>\n\n<code>{vless}</code>", parse_mode="HTML")


async def _show_info(message: Message, name: str):
    client = await db.get_client(name)
    if not client:
        await message.answer(f"Client '{name}' not found.")
        return

    vless = generate_vless_link(
        uuid=client["uuid"],
        name=name,
        server_ip=RUSSIA_IP,
        reality_public_key=REALITY_PUBLIC_KEY,
        short_id=REALITY_SHORT_ID,
    )
    await message.answer(
        f"Name: <b>{client['name']}</b>\n"
        f"UUID: <code>{client['uuid']}</code>\n"
        f"Note: {client['note'] or '—'}\n"
        f"Created: {client['created_at']}\n\n"
        f"VLESS:\n<code>{vless}</code>",
        parse_mode="HTML",
    )


async def main():
    await db.init_db()

    await bot.set_my_commands([
        BotCommand(command="start", description="Main menu"),
        BotCommand(command="add", description="Add client: /add name [note]"),
        BotCommand(command="list", description="List clients"),
        BotCommand(command="link", description="Get VLESS link: /link name"),
        BotCommand(command="info", description="Client info: /info name"),
        BotCommand(command="note", description="Set note: /note name text"),
    ])

    logger.info("VPNSmart bot started")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
