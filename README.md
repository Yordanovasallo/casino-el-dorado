# ♛ Casino El Dorado — Multijugador

Juego de casino (ruletas y raspa y gana) que guarda todo en la nube con **Firebase**, para que tú y tus amigos jueguen **la misma partida** en tiempo real desde cualquier dispositivo.

Solo necesitas hacer **una vez** la configuración de Firebase (gratis) que se explica abajo.

---

## 1. Crear el proyecto de Firebase

1. Entra a https://console.firebase.google.com/ e inicia sesión con tu cuenta Google.
2. Clic en **Agregar proyecto** → ponle un nombre (ej: `casino-el-dorado`) → Continúa (puedes desactivar Google Analytics) → **Crear proyecto**.
3. En el menú lateral ve a **Compilación → Firestore Database → Crear base de datos**.
   - Elige una ubicación (ej: `us-central`).
   - Empieza en **modo de prueba** (luego pegarás las reglas del paso 3) → **Crear**.
4. Vuelve a la página principal del proyecto y haz clic en el icono **`</>`** (Web) para registrar una app.
   - Ponle un nombre (ej: `casino web`) y **Registrar app**. No necesitas Firebase Hosting.
5. Firebase te mostrará un objeto `firebaseConfig`. **Cópialo completo**.

## 2. Pegar la configuración en el juego

Abre el archivo `index.html` y busca al inicio del `<script>`:

```js
const firebaseConfig = {
  apiKey: "PEGA_AQUI_TU_API_KEY",
  authDomain: "PEGA_AQUI.firebaseapp.com",
  projectId: "PEGA_AQUI",
  storageBucket: "PEGA_AQUI.appspot.com",
  messagingSenderId: "000000000000",
  appId: "1:000000000000:web:PEGA_AQUI"
};
```

Reemplaza esos valores por los de tu proyecto. Puedes editarlo directamente aquí en GitHub: abre `index.html` y usa el botón del lápiz ✏️ → pega → **Commit changes**.

> Mientras no lo configures, el juego muestra un aviso: “Falta conectar Firebase”.

## 3. Publicar las reglas de Firestore

1. En Firebase ve a **Firestore Database → pestaña Reglas**.
2. Borra lo que haya y pega el contenido del archivo `firestore.rules` de este repositorio.
3. Clic en **Publicar**.

> ⚠️ Estas reglas son **abiertas** (pensadas para un grupo de amigos). Cualquiera con la URL del juego puede leer y modificar los datos. No uses dinero real.

## 4. Activar GitHub Pages

1. En este repositorio ve a **Settings → Pages**.
2. En **Source** elige: **Deploy from a branch**.
3. En **Branch** selecciona **`main`** y carpeta **`/ (root)`** → **Save**.
4. Espera 1–2 minutos. Tu URL será:

```
https://YORDANOVASALLO.github.io/casino-el-dorado/
```

---

## Cómo se juega

- Cada amigo entra a la URL y crea su cuenta (usuario y contraseña). Empiezan con **100 fichas**.
- El primer usuario que se registre con el nombre **`admin`** obtiene el **Panel de administración** (dar/quitar fichas, ver todos los movimientos). Elige una contraseña que no sea obvia.
- Juegos:
  - 🎡 **Ruleta**: una ronda por hora, cuesta 50 fichas.
  - ⚡ **Ruleta Rápida**: una ronda por minuto, cuesta 5 fichas.
  - 🎟️ **Raspa y Gana**: 10 fichas por cartón, premios hasta 1000.
- Todos ven la misma ronda y el mismo ganador en tiempo real.

## Ajustes rápidos (en `index.html`)

- `const SALDO_INICIAL = 100;` → fichas con las que empieza cada cuenta nueva.
- El número de WhatsApp para recargas está en `const WA = "https://wa.me/58097787";` (cámbialo por el tuyo).

## Avisos

- Es una **demo**. Las contraseñas se guardan con un hash SHA-256, no en texto plano, pero no es un sistema de seguridad bancario.
- Si el proyecto crece, conviene cerrar las reglas de Firestore y añadir reglas de administrador.
- El repo debe ser **público** para que GitHub Pages funcione gratis.
