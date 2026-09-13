from flask import Flask, render_template, request, redirect, url_for, session, flash
from werkzeug.utils import secure_filename
import sqlite3
import os
from datetime import datetime

app = Flask(__name__)
app.secret_key = "hachemi-market-secret"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "market.db")
UPLOAD_FOLDER = os.path.join(BASE_DIR, "static", "uploads")

os.makedirs(UPLOAD_FOLDER, exist_ok=True)

ADMIN_USER = "Hachemi"
ADMIN_PASSWORD = "Hachemi"


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()

    conn.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            price REAL NOT NULL,
            stock INTEGER NOT NULL DEFAULT 0,
            description TEXT NOT NULL,
            image TEXT
        )
    """)

    conn.execute("""
        CREATE TABLE IF NOT EXISTS reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            rating INTEGER NOT NULL,
            comment TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(product_id) REFERENCES products(id)
        )
    """)

    conn.commit()
    conn.close()


def sunday_discount():
    return datetime.now().weekday() == 6


def final_price(price):
    if sunday_discount():
        return round(price * 0.90, 2)
    return round(price, 2)


def get_average(product_id):
    conn = get_db()
    result = conn.execute(
        "SELECT AVG(rating) AS average FROM reviews WHERE product_id = ?",
        (product_id,)
    ).fetchone()
    conn.close()

    return round(result["average"], 1) if result["average"] else 0


@app.route("/")
def index():
    conn = get_db()
    products = conn.execute("SELECT * FROM products ORDER BY id DESC").fetchall()
    conn.close()

    return render_template(
        "index.html",
        products=products,
        sunday=sunday_discount(),
        final_price=final_price,
        get_average=get_average
    )


@app.route("/product/<int:product_id>")
def product(product_id):
    conn = get_db()

    product = conn.execute(
        "SELECT * FROM products WHERE id = ?",
        (product_id,)
    ).fetchone()

    reviews = conn.execute(
        "SELECT * FROM reviews WHERE product_id = ? ORDER BY id DESC",
        (product_id,)
    ).fetchall()

    conn.close()

    if not product:
        return "Produit introuvable", 404

    return render_template(
        "product.html",
        product=product,
        reviews=reviews,
        average=get_average(product_id),
        sunday=sunday_discount(),
        final_price=final_price
    )


@app.post("/product/<int:product_id>/review")
def add_review(product_id):
    rating = request.form.get("rating", type=int)
    comment = request.form.get("comment", "").strip()

    if rating not in range(1, 6) or not comment:
        flash("Avis invalide.", "error")
        return redirect(url_for("product", product_id=product_id))

    conn = get_db()
    exists = conn.execute(
        "SELECT id FROM products WHERE id = ?",
        (product_id,)
    ).fetchone()

    if not exists:
        conn.close()
        return "Produit introuvable", 404

    conn.execute(
        """
        INSERT INTO reviews(product_id, rating, comment, created_at)
        VALUES (?, ?, ?, ?)
        """,
        (product_id, rating, comment, datetime.now().strftime("%d/%m/%Y"))
    )

    conn.commit()
    conn.close()

    flash("Merci pour votre avis !", "success")
    return redirect(url_for("product", product_id=product_id))


@app.post("/buy/<int:product_id>")
def buy(product_id):
    conn = get_db()

    product = conn.execute(
        "SELECT * FROM products WHERE id = ?",
        (product_id,)
    ).fetchone()

    conn.close()

    if not product:
        return "Produit introuvable", 404

    if product["stock"] <= 0:
        flash("Produit indisponible.", "error")
        return redirect(url_for("product", product_id=product_id))

    flash("Merci de votre achat !", "success")
    return redirect(url_for("product", product_id=product_id))


@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")

        if username == ADMIN_USER and password == ADMIN_PASSWORD:
            session["admin"] = True
            return redirect(url_for("admin"))

        flash("Identifiants incorrects.", "error")

    return render_template("login.html")


@app.route("/admin/logout")
def admin_logout():
    session.pop("admin", None)
    return redirect(url_for("index"))


def admin_required():
    return session.get("admin") is True


@app.route("/admin")
def admin():
    if not admin_required():
        return redirect(url_for("admin_login"))

    conn = get_db()
    products = conn.execute("SELECT * FROM products ORDER BY id DESC").fetchall()
    conn.close()

    return render_template("admin.html", products=products)


@app.post("/admin/add")
def admin_add():
    if not admin_required():
        return redirect(url_for("admin_login"))

    name = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    price = request.form.get("price", type=float)
    stock = request.form.get("stock", type=int)

    image = request.files.get("image")
    image_name = ""

    if image and image.filename:
        image_name = secure_filename(image.filename)
        image.save(os.path.join(UPLOAD_FOLDER, image_name))

    if not name or price is None or stock is None:
        flash("Informations invalides.", "error")
        return redirect(url_for("admin"))

    conn = get_db()
    conn.execute(
        """
        INSERT INTO products(name, price, stock, description, image)
        VALUES (?, ?, ?, ?, ?)
        """,
        (name, price, stock, description, image_name)
    )
    conn.commit()
    conn.close()

    flash("Produit ajouté.", "success")
    return redirect(url_for("admin"))


@app.post("/admin/delete/<int:product_id>")
def admin_delete(product_id):
    if not admin_required():
        return redirect(url_for("admin_login"))

    conn = get_db()

    conn.execute("DELETE FROM reviews WHERE product_id = ?", (product_id,))
    conn.execute("DELETE FROM products WHERE id = ?", (product_id,))

    conn.commit()
    conn.close()

    flash("Produit supprimé.", "success")
    return redirect(url_for("admin"))


@app.post("/admin/restock/<int:product_id>")
def admin_restock(product_id):
    if not admin_required():
        return redirect(url_for("admin_login"))

    amount = request.form.get("amount", type=int)

    if amount is None or amount < 0:
        return redirect(url_for("admin"))

    conn = get_db()
    conn.execute(
        "UPDATE products SET stock = stock + ? WHERE id = ?",
        (amount, product_id)
    )
    conn.commit()
    conn.close()

    flash("Stock mis à jour.", "success")
    return redirect(url_for("admin"))


@app.post("/admin/edit/<int:product_id>")
def admin_edit(product_id):
    if not admin_required():
        return redirect(url_for("admin_login"))

    name = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    price = request.form.get("price", type=float)
    stock = request.form.get("stock", type=int)

    image = request.files.get("image")

    conn = get_db()

    if image and image.filename:
        image_name = secure_filename(image.filename)
        image.save(os.path.join(UPLOAD_FOLDER, image_name))

        conn.execute(
            """
            UPDATE products
            SET name = ?, price = ?, stock = ?, description = ?, image = ?
            WHERE id = ?
            """,
            (name, price, stock, description, image_name, product_id)
        )
    else:
        conn.execute(
            """
            UPDATE products
            SET name = ?, price = ?, stock = ?, description = ?
            WHERE id = ?
            """,
            (name, price, stock, description, product_id)
        )

    conn.commit()
    conn.close()

    flash("Produit modifié.", "success")
    return redirect(url_for("admin"))


init_db()


if __name__ == "__main__":
    app.run(debug=True)
