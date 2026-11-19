import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { AuthProvider } from "./context/AuthContext";
import { ProfileProvider } from "./context/ProfileContext";
import { UserDataProvider } from "./context/UserDataContext";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")).render(
  <BrowserRouter>
    <AuthProvider>
      <ProfileProvider>
        <UserDataProvider>
          <App />
        </UserDataProvider>
      </ProfileProvider>
    </AuthProvider>
  </BrowserRouter>
);

// Service worker: nodig om Streamify als app te kunnen installeren (werkt alleen via HTTPS).
if ("serviceWorker" in navigator && window.isSecureContext) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  });
}
