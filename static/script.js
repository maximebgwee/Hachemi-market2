async function buyProduct(id, button) {
    if (button.disabled) return;
    const original = button.textContent;
    button.disabled = true;
    button.textContent = "Traitement...";
    try {
        const response = await fetch(`/buy/${id}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" }
        });
        const data = await response.json();
        if (data.success) {
            button.textContent = "✓ Merci de votre achat !";
            setTimeout(() => {
                button.textContent = original;
                button.disabled = false;
            }, 3000);
        } else {
            button.textContent = data.message;
            button.classList.add("disabled");
        }
    } catch (error) {
        button.textContent = "Une erreur est survenue";
        setTimeout(() => {
            button.textContent = original;
            button.disabled = false;
        }, 2500);
    }
}

const observer = new IntersectionObserver(
    entries => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add("visible");
                observer.unobserve(entry.target);
            }
        });
    },
    { threshold: 0.12 }
);

document.querySelectorAll(".reveal").forEach(element => observer.observe(element));
