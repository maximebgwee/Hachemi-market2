import os
import sqlite3
from datetime import datetime
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "hachemi-market-secret-change-me")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(BASE_DIR, "market.db")
UPLOAD_FOLDER = os.path.join(BASE_DIR, "static", "uploads")

os.makedirs(UPLOAD_FOLDER, exist_ok=True)

ADMIN_USER = "Hachemi"
ADMIN_PASSWORD = "Hachemi"


def db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = db()

    conn.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            price REAL NOT NULL,
            stock INTEGER NOT NULL DEFAULT 0,
            image TEXT DEFAULT '',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    conn.execute("""
        CREATE TABLE IF NOT EXISTS reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            rating INTEGER NOT NULL,
            comment TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
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


def admin_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("admin"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return wrapper


@app.template_filter("price")
def price_filter(value):
    return f"{value:.2f}".replace(".", ",") + " €"


@app.context_processor
def inject_globals():
    return {
        "sunday": sunday_discount(),
        "final_price": final_price
    }


@app.route("/")
def index():
    conn = db()
    products = conn.execute(
        "SELECT * FROM products ORDER BY id DESC"
    ).fetchall()

    reviews = {}
    for product in products:
        reviews[product["id"]] = conn.execute(
            "SELECT AVG(rating) AS average, COUNT(*) AS count "
            "FROM reviews WHERE product_id = ?",
            (product["id"],)
        ).fetchone()

    conn.close()

    return render_template("index.html", products=products, reviews=reviews)


@app.route("/product/<int:product_id>")
def product(product_id):
    conn = db()
    item = conn.execute("SELECT * FROM products WHERE id = ?", (product_id,)).fetchone()
    if not item:
        conn.close()
        return "Produit introuvable", 404

    reviews = conn.execute(
        "SELECT * FROM reviews WHERE product_id = ? ORDER BY id DESC",
        (product_id,),
    ).fetchall()

    stats = conn.execute(
        "SELECT AVG(rating) AS average, COUNT(*) AS count FROM reviews WHERE product_id = ?",
        (product_id,),
    ).fetchone()

    conn.close()
    return render_template("product.html", product=item, reviews=reviews, stats=stats)


@app.route("/product/<int:product_id>/review", methods=["POST"])
def add_review(product_id):
    rating = request.form.get("rating", type=int)
    comment = request.form.get("comment", "").strip()

    if rating not in range(1, 6):
        flash("Note invalide.")
        return redirect(url_for("product", product_id=product_id))

    if not comment:
        flash("Veuillez écrire un commentaire.")
        return redirect(url_for("product", product_id=product_id))

    conn = db()
    exists = conn.execute("SELECT id FROM products WHERE id = ?", (product_id,)).fetchone()
    if not exists:
        conn.close()
        return "Produit introuvable", 404

    conn.execute(
        "INSERT INTO reviews(product_id, rating, comment) VALUES (?, ?, ?)",
        (product_id, rating, comment),
    )
    conn.commit()
    conn.close()

    flash("Merci pour votre avis !")
    return redirect(url_for("product", product_id=product_id))


@app.route("/buy/<int:product_id>", methods=["POST"])
def buy(product_id):
    conn = db()
    item = conn.execute("SELECT * FROM products WHERE id = ?", (product_id,)).fetchone()

    if not item:
        conn.close()
        return jsonify({"success": False, "message": "Produit introuvable."}), 404

    if item["stock"] <= 0:
        conn.close()
        return jsonify({"success": False, "message": "Ce produit est actuellement indisponible."}), 400

    conn.close()
    return jsonify({"success": True, "message": "Merci de votre achat !"})


@app.route("/admin/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")

        if username == ADMIN_USER and password == ADMIN_PASSWORD:
            session["admin"] = True
            return redirect(url_for("admin"))

        flash("Identifiant ou mot de passe incorrect.")

    return render_template("login.html")


@app.route("/admin/logout")
def logout():
    session.clear()
    return redirect(url_for("index"))


@app.route("/admin")
@admin_required
def admin():
    conn = db()
    products = conn.execute("SELECT * FROM products ORDER BY id DESC").fetchall()
    conn.close()
    return render_template("admin.html", products=products)


@app.route("/admin/add", methods=["POST"])
@admin_required
def add_product():
    name = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    price = request.form.get("price", type=float)
    stock = request.form.get("stock", type=int)
    image = request.files.get("image")

    if not name or price is None or price < 0 or stock is None or stock < 0:
        flash("Informations invalides.")
        return redirect(url_for("admin"))

    filename = ""
    if image and image.filename:
        filename = secure_filename(image.filename)
        image.save(os.path.join(UPLOAD_FOLDER, filename))

    conn = db()
    conn.execute(
        """
        INSERT INTO products(name, description, price, stock, image)
        VALUES (?, ?, ?, ?, ?)
        """,
        (name, description, price, stock, filename),
    )
    conn.commit()
    conn.close()

    flash("Produit ajouté avec succès.")
    return redirect(url_for("admin"))


@app.route("/admin/delete/<int:product_id>", methods=["POST"])
@admin_required
def delete_product(product_id):
    conn = db()
    conn.execute("DELETE FROM reviews WHERE product_id = ?", (product_id,))
    conn.execute("DELETE FROM products WHERE id = ?", (product_id,))
    conn.commit()
    conn.close()

    flash("Produit supprimé.")
    return redirect(url_for("admin"))


@app.route("/admin/restock/<int:product_id>", methods=["POST"])
@admin_required
def restock(product_id):
    amount = request.form.get("amount", type=int)

    if amount is None or amount <= 0:
        flash("Quantité invalide.")
        return redirect(url_for("admin"))

    conn = db()
    conn.execute("UPDATE products SET stock = stock + ? WHERE id = ?", (amount, product_id))
    conn.commit()
    conn.close()

    flash("Stock réapprovisionné.")
    return redirect(url_for("admin"))


@app.route("/admin/edit/<int:product_id>", methods=["POST"])
@admin_required
def edit_product(product_id):
    name = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    price = request.form.get("price", type=float)

    if not name or price is None or price < 0:
        flash("Informations invalides.")
        return redirect(url_for("admin"))

    conn = db()
    conn.execute(
        """
        UPDATE products
        SET name = ?, description = ?, price = ?
        WHERE id = ?
        """,
        (name, description, price, product_id),
    )
    conn.commit()
    conn.close()

    flash("Produit modifié.")
    return redirect(url_for("admin"))


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
