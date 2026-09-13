#!/bin/bash
set -e

echo "🧹 Nettoyage..."

rm -rf app.py requirements.txt wsgi.py templates static market.db .gitignore

mkdir -p templates static/uploads

echo "📦 Création de requirements.txt..."

cat > requirements.txt <<'EOF'
Flask==3.1.1
Werkzeug==3.1.3
EOF

echo "🐍 Création de app.py..."

cat > app.py <<'PY'
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
PY

echo "🌐 Création de wsgi.py..."

cat > wsgi.py <<'PY'
import sys
import os

project_home = os.path.dirname(os.path.abspath(__file__))

if project_home not in sys.path:
    sys.path.insert(0, project_home)

from app import app as application
PY

echo "🎨 Création du site..."

cat > templates/base.html <<'HTML'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}Hachemi Market{% endblock %}</title>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Fraunces:wght@600;700&family=Work+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">

    <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>

<body>

<header>
    <div class="header-inner">
        <a href="{{ url_for('index') }}" class="logo">Hachemi Market</a>

        <nav>
            <a href="{{ url_for('index') }}">Accueil</a>
            <a href="{{ url_for('admin_login') }}">Administration</a>
        </nav>
    </div>
</header>

{% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
        <div class="messages">
            {% for category, message in messages %}
                <div class="message {{ category }}">{{ message }}</div>
            {% endfor %}
        </div>
    {% endif %}
{% endwith %}

<main>
    {% block content %}{% endblock %}
</main>

<footer>
    <strong>Hachemi Market</strong>
    <p>Créateur : Hachemi ._. </p>
</footer>

<script src="{{ url_for('static', filename='script.js') }}"></script>

</body>
</html>
HTML

cat > templates/index.html <<'HTML'
{% extends "base.html" %}

{% block title %}Hachemi Market{% endblock %}

{% block content %}

<section class="hero reveal">
    <span class="eyebrow">Depuis 2014</span>
    <h1>Le marché selon Hachemi.</h1>

    <p>
        Une sélection pensée avec simplicité, caractère et une vraie
        attention portée à chaque produit.
    </p>

    <p class="signature">Hachemi, fondateur</p>
</section>

{% if sunday %}
<div class="promotion reveal">
    <strong>DIMANCHE</strong>
    <span>-10% sur tous les produits</span>
</div>
{% endif %}

<section class="catalog reveal">
    <div class="section-heading">
        <div>
            <span class="eyebrow">Notre sélection</span>
            <h2>Les produits</h2>
        </div>
    </div>

    {% if products %}

    <div class="products">

        {% for product in products %}

        <article class="card">

            <a href="{{ url_for('product', product_id=product.id) }}">
                {% if product.image %}
                    <img src="{{ url_for('static', filename='uploads/' + product.image) }}" alt="{{ product.name }}">
                {% else %}
                    <div class="no-image">Hachemi Market</div>
                {% endif %}
            </a>

            <div class="card-body">

                <a href="{{ url_for('product', product_id=product.id) }}">
                    <h3>{{ product.name }}</h3>
                </a>

                <p>{{ product.description }}</p>

                <div class="price">

                    {% if sunday %}
                        <span class="old-price">{{ "%.2f"|format(product.price) }} €</span>
                        <span>{{ "%.2f"|format(final_price(product.price)) }} €</span>
                        <b>-10%</b>
                    {% else %}
                        <span>{{ "%.2f"|format(product.price) }} €</span>
                    {% endif %}

                </div>

                <div class="stock">
                    {% if product.stock > 0 %}
                        {{ product.stock }} en stock
                    {% else %}
                        Rupture de stock
                    {% endif %}
                </div>

                <a class="button secondary" href="{{ url_for('product', product_id=product.id) }}">
                    Voir le produit
                </a>

            </div>
        </article>

        {% endfor %}

    </div>

    {% else %}

    <div class="empty">
        Aucun produit pour le moment.
    </div>

    {% endif %}
</section>

{% endblock %}
HTML

cat > templates/product.html <<'HTML'
{% extends "base.html" %}

{% block title %}{{ product.name }} — Hachemi Market{% endblock %}

{% block content %}

<section class="product-page reveal">

    <a href="{{ url_for('index') }}" class="back">← Retour au marché</a>

    <div class="product-layout">

        <div class="product-image">

            {% if product.image %}
                <img src="{{ url_for('static', filename='uploads/' + product.image) }}" alt="{{ product.name }}">
            {% else %}
                <div class="no-image">Hachemi Market</div>
            {% endif %}

        </div>

        <div class="product-info">

            <span class="eyebrow">Produit</span>

            <h1>{{ product.name }}</h1>

            <p class="description">{{ product.description }}</p>

            <div class="price large">

                {% if sunday %}
                    <span class="old-price">{{ "%.2f"|format(product.price) }} €</span>
                    <span>{{ "%.2f"|format(final_price(product.price)) }} €</span>
                    <b>-10%</b>
                {% else %}
                    <span>{{ "%.2f"|format(product.price) }} €</span>
                {% endif %}

            </div>

            <p class="stock">
                {% if product.stock > 0 %}
                    {{ product.stock }} en stock
                {% else %}
                    Rupture de stock
                {% endif %}
            </p>

            {% if product.stock > 0 %}

            <form action="{{ url_for('buy', product_id=product.id) }}" method="POST">
                <button class="button" type="submit">Acheter</button>
            </form>

            {% else %}

            <button class="button disabled" disabled>
                Indisponible
            </button>

            {% endif %}

        </div>

    </div>

</section>

<section class="reviews reveal">

    <div class="section-heading">
        <div>
            <span class="eyebrow">Avis clients</span>
            <h2>Les avis</h2>
        </div>

        <div class="rating">
            ★ {{ average }}/5
        </div>
    </div>

    <form class="review-form" action="{{ url_for('add_review', product_id=product.id) }}" method="POST">

        <select name="rating" required>
            <option value="">Note</option>
            <option value="5">★★★★★ — 5</option>
            <option value="4">★★★★☆ — 4</option>
            <option value="3">★★★☆☆ — 3</option>
            <option value="2">★★☆☆☆ — 2</option>
            <option value="1">★☆☆☆☆ — 1</option>
        </select>

        <textarea name="comment" placeholder="Votre commentaire..." required></textarea>

        <button class="button" type="submit">Publier mon avis</button>

    </form>

    <div class="review-list">

        {% for review in reviews %}

        <article class="review">
            <div class="stars">
                {{ "★" * review.rating }}{{ "☆" * (5 - review.rating) }}
            </div>

            <p>{{ review.comment }}</p>

            <small>{{ review.created_at }}</small>
        </article>

        {% else %}

        <p>Aucun avis pour le moment.</p>

        {% endfor %}

    </div>

</section>

{% endblock %}
HTML

cat > templates/login.html <<'HTML'
{% extends "base.html" %}

{% block title %}Administration — Hachemi Market{% endblock %}

{% block content %}

<section class="login-page reveal">

    <span class="eyebrow">Administration</span>
    <h1>Connexion</h1>

    <form method="POST" class="admin-form">

        <label>Nom d'utilisateur</label>
        <input type="text" name="username" required>

        <label>Mot de passe</label>
        <input type="password" name="password" required>

        <button class="button" type="submit">Se connecter</button>

    </form>

</section>

{% endblock %}
HTML

cat > templates/admin.html <<'HTML'
{% extends "base.html" %}

{% block title %}Administration — Hachemi Market{% endblock %}

{% block content %}

<section class="admin-page reveal">

    <div class="admin-header">

        <div>
            <span class="eyebrow">Espace privé</span>
            <h1>Administration</h1>
        </div>

        <a class="button secondary" href="{{ url_for('admin_logout') }}">
            Déconnexion
        </a>

    </div>

    <section class="admin-box">

        <h2>Ajouter un produit</h2>

        <form method="POST" action="{{ url_for('admin_add') }}" enctype="multipart/form-data" class="admin-form">

            <input name="name" placeholder="Nom du produit" required>

            <input name="price" type="number" step="0.01" placeholder="Prix" required>

            <input name="stock" type="number" min="0" placeholder="Stock" required>

            <textarea name="description" placeholder="Description" required></textarea>

            <input name="image" type="file" accept="image/*">

            <button class="button" type="submit">Ajouter</button>

        </form>

    </section>

    <section class="admin-box">

        <h2>Produits</h2>

        {% for product in products %}

        <div class="admin-product">

            <div>
                <strong>{{ product.name }}</strong>
                <span>{{ "%.2f"|format(product.price) }} € · {{ product.stock }} stock</span>
            </div>

            <div class="admin-actions">

                <form method="POST" action="{{ url_for('admin_restock', product_id=product.id) }}">
                    <input type="number" name="amount" min="1" placeholder="+ stock" required>
                    <button class="button small" type="submit">Restocker</button>
                </form>

                <form method="POST" action="{{ url_for('admin_delete', product_id=product.id) }}"
                      onsubmit="return confirm('Supprimer ce produit ?');">
                    <button class="button danger small" type="submit">Supprimer</button>
                </form>

            </div>

            <details>
                <summary>Modifier</summary>

                <form method="POST"
                      action="{{ url_for('admin_edit', product_id=product.id) }}"
                      enctype="multipart/form-data"
                      class="admin-form">

                    <input name="name" value="{{ product.name }}" required>

                    <input name="price" type="number" step="0.01" value="{{ product.price }}" required>

                    <input name="stock" type="number" min="0" value="{{ product.stock }}" required>

                    <textarea name="description" required>{{ product.description }}</textarea>

                    <input name="image" type="file" accept="image/*">

                    <button class="button" type="submit">Enregistrer</button>

                </form>

            </details>

        </div>

        {% else %}

        <p>Aucun produit.</p>

        {% endfor %}

    </section>

</section>

{% endblock %}
HTML

echo "🎨 Création du CSS..."

cat > static/style.css <<'CSS'
:root {
    --paper: #f4eddf;
    --paper-dark: #e8dcc7;
    --green: #315b43;
    --green-dark: #203d2d;
    --mustard: #c49435;
    --ink: #29271f;
    --muted: #756f62;
    --white: #fffdf8;
    --danger: #8b3028;
}

* {
    box-sizing: border-box;
}

body {
    margin: 0;
    background: var(--paper);
    color: var(--ink);
    font-family: "Work Sans", sans-serif;
}

h1,
h2,
h3 {
    font-family: "Fraunces", serif;
}

a {
    color: inherit;
    text-decoration: none;
}

header {
    border-bottom: 1px solid #d5c9b5;
    background: var(--paper);
}

.header-inner {
    max-width: 1180px;
    margin: auto;
    padding: 22px 24px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.logo {
    font-family: "Fraunces", serif;
    font-size: 25px;
    font-weight: 700;
}

nav {
    display: flex;
    gap: 24px;
    color: var(--muted);
}

nav a:hover {
    color: var(--green);
}

main {
    max-width: 1180px;
    margin: auto;
    padding: 0 24px 80px;
}

.hero {
    padding: 100px 0 70px;
    max-width: 800px;
}

.hero h1 {
    font-size: clamp(48px, 8vw, 88px);
    line-height: .95;
    margin: 15px 0 25px;
}

.hero p {
    color: var(--muted);
    font-size: 18px;
    line-height: 1.7;
    max-width: 650px;
}

.signature {
    color: var(--green) !important;
    font-family: "Fraunces", serif;
    font-size: 20px !important;
    margin-top: 35px;
}

.eyebrow {
    color: var(--mustard);
    text-transform: uppercase;
    letter-spacing: .14em;
    font-size: 12px;
    font-weight: 700;
}

.promotion {
    border: 2px solid var(--mustard);
    padding: 18px 22px;
    display: flex;
    gap: 15px;
    margin-bottom: 70px;
}

.promotion strong {
    color: var(--green);
}

.section-heading {
    display: flex;
    justify-content: space-between;
    align-items: end;
    margin-bottom: 28px;
}

.section-heading h2 {
    font-size: 42px;
    margin: 8px 0 0;
}

.products {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 22px;
}

.card {
    background: var(--white);
    border: 1px solid #ddd1bd;
}

.card img,
.product-image img {
    width: 100%;
    height: 280px;
    object-fit: cover;
    display: block;
}

.no-image {
    height: 280px;
    display: grid;
    place-items: center;
    background: var(--paper-dark);
    color: var(--green);
    font-family: "Fraunces", serif;
    font-size: 22px;
}

.card-body {
    padding: 25px;
}

.card h3 {
    font-size: 25px;
    margin: 0 0 12px;
}

.card p,
.description {
    color: var(--muted);
    line-height: 1.6;
}

.price {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 20px 0 8px;
    font-size: 22px;
    font-weight: 700;
}

.price.large {
    font-size: 32px;
}

.old-price {
    text-decoration: line-through;
    color: var(--muted);
    font-size: 17px;
    font-weight: 400;
}

.price b {
    font-size: 12px;
    background: var(--mustard);
    color: white;
    padding: 5px 7px;
}

.stock {
    color: var(--green);
    font-size: 14px;
    margin-bottom: 20px;
}

.button {
    display: inline-block;
    border: 0;
    background: var(--green);
    color: white;
    padding: 13px 20px;
    cursor: pointer;
    font: inherit;
    font-weight: 600;
}

.button:hover {
    background: var(--green-dark);
}

.button.secondary {
    background: transparent;
    border: 1px solid var(--green);
    color: var(--green);
}

.button.danger {
    background: var(--danger);
}

.button.disabled {
    opacity: .45;
    cursor: not-allowed;
}

.button.small {
    padding: 9px 12px;
    font-size: 13px;
}

.product-page {
    padding-top: 45px;
}

.back {
    color: var(--green);
    display: inline-block;
    margin-bottom: 30px;
}

.product-layout {
    display: grid;
    grid-template-columns: 1.1fr .9fr;
    gap: 60px;
}

.product-image img,
.product-image .no-image {
    height: 550px;
}

.product-info {
    padding: 30px 0;
}

.product-info h1 {
    font-size: 60px;
    line-height: 1;
    margin: 15px 0 25px;
}

.reviews {
    padding-top: 90px;
}

.rating {
    color: var(--mustard);
    font-weight: 700;
}

.review-form,
.admin-form {
    display: grid;
    gap: 14px;
    max-width: 700px;
}

input,
textarea,
select {
    border: 1px solid #d0c3ae;
    background: var(--white);
    padding: 14px;
    font: inherit;
    color: var(--ink);
}

textarea {
    min-height: 120px;
    resize: vertical;
}

.review-list {
    margin-top: 35px;
    display: grid;
    gap: 14px;
}

.review {
    border-top: 1px solid #d5c9b5;
    padding: 20px 0;
}

.stars {
    color: var(--mustard);
    letter-spacing: 2px;
}

.review p {
    line-height: 1.6;
}

.review small {
    color: var(--muted);
}

.login-page {
    max-width: 500px;
    margin: 100px auto;
}

.login-page h1,
.admin-page h1 {
    font-size: 55px;
    margin-top: 10px;
}

.admin-page {
    padding-top: 60px;
}

.admin-header {
    display: flex;
    justify-content: space-between;
    align-items: end;
    margin-bottom: 40px;
}

.admin-box {
    background: var(--white);
    border: 1px solid #ddd1bd;
    padding: 30px;
    margin-bottom: 25px;
}

.admin-product {
    border-top: 1px solid #ddd1bd;
    padding: 22px 0;
}

.admin-product > div:first-child {
    display: flex;
    justify-content: space-between;
    margin-bottom: 15px;
}

.admin-product span {
    color: var(--muted);
}

.admin-actions {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
}

.admin-actions form {
    display: flex;
    gap: 7px;
}

details {
    margin-top: 20px;
}

summary {
    cursor: pointer;
    color: var(--green);
    font-weight: 600;
    margin-bottom: 15px;
}

.messages {
    max-width: 1180px;
    margin: 20px auto 0;
    padding: 0 24px;
}

.message {
    padding: 15px 18px;
    border-left: 4px solid var(--green);
    background: var(--white);
}

.message.error {
    border-left-color: var(--danger);
}

footer {
    border-top: 1px solid #d5c9b5;
    padding: 35px 24px;
    text-align: center;
    color: var(--muted);
}

footer strong {
    font-family: "Fraunces", serif;
    color: var(--green);
}

.reveal {
    animation: reveal .7s ease both;
}

@keyframes reveal {
    from {
        opacity: 0;
        transform: translateY(18px);
    }

    to {
        opacity: 1;
        transform: translateY(0);
    }
}

.empty {
    padding: 50px;
    border: 1px dashed #c8baa3;
    text-align: center;
}

@media (max-width: 800px) {
    .products {
        grid-template-columns: 1fr;
    }

    .product-layout {
        grid-template-columns: 1fr;
        gap: 20px;
    }

    .product-info h1 {
        font-size: 45px;
    }

    .product-image img,
    .product-image .no-image {
        height: 350px;
    }

    .header-inner {
        align-items: flex-start;
        gap: 20px;
    }

    nav {
        gap: 12px;
        font-size: 14px;
    }

    .admin-header {
        align-items: flex-start;
        gap: 20px;
        flex-direction: column;
    }
}
CSS

cat > static/script.js <<'JS'
document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".reveal").forEach((element, index) => {
        element.style.animationDelay = `${index * 80}ms`;
    });
});
JS

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.venv/
.env
market.db
EOF

cat > static/uploads/.gitkeep <<'EOF'
EOF

echo "🐍 Initialisation locale..."

python3 -m venv .venv 2>/dev/null || true

echo "🗄️ Initialisation de la base..."

if [ -x ".venv/bin/python" ]; then
    .venv/bin/pip install -q -r requirements.txt
    .venv/bin/python -c "from app import init_db; init_db()"
fi

echo ""
echo "======================================"
echo " HACHEMI MARKET PRÊT"
echo "======================================"
echo ""
echo "Fichiers créés :"
echo "- app.py"
echo "- requirements.txt"
echo "- wsgi.py"
echo "- templates/"
echo "- static/"
echo ""
echo "Pour envoyer sur GitHub :"
echo ""
echo "git add ."
echo "git commit -m 'Création complète de Hachemi Market'"
echo "git push origin hachemi-market"
echo ""
