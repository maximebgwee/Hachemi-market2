document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".reveal").forEach((element, index) => {
        element.style.animationDelay = `${index * 80}ms`;
    });
});
