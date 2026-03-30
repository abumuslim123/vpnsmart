import aiosqlite
import os

DB_PATH = os.getenv("DB_PATH", "/data/vpnsmart.db")


async def init_db():
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS clients (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                uuid TEXT UNIQUE NOT NULL,
                note TEXT DEFAULT '',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        await db.commit()


async def add_client(name: str, uuid: str, note: str = "") -> dict:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            "INSERT INTO clients (name, uuid, note) VALUES (?, ?, ?)",
            (name, uuid, note),
        )
        await db.commit()
        async with db.execute(
            "SELECT * FROM clients WHERE name = ?", (name,)
        ) as cursor:
            row = await cursor.fetchone()
            return dict(row)


async def get_client(name: str) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM clients WHERE name = ?", (name,)
        ) as cursor:
            row = await cursor.fetchone()
            return dict(row) if row else None


async def list_clients() -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM clients ORDER BY created_at DESC"
        ) as cursor:
            rows = await cursor.fetchall()
            return [dict(r) for r in rows]


async def delete_client(name: str) -> bool:
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute("DELETE FROM clients WHERE name = ?", (name,))
        await db.commit()
        return cursor.rowcount > 0


async def update_note(name: str, note: str) -> bool:
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "UPDATE clients SET note = ? WHERE name = ?", (note, name)
        )
        await db.commit()
        return cursor.rowcount > 0


async def get_all_uuids() -> list[dict]:
    """Return all clients with name and uuid for Xray config generation."""
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT name, uuid FROM clients") as cursor:
            rows = await cursor.fetchall()
            return [dict(r) for r in rows]
