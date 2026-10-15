import { Routes, Route } from "react-router-dom";
import Home from "./pages/Home";
import Watch from "./pages/Watch";
import Settings from "./pages/Settings";
import Kids from "./pages/Kids";
import Person from "./pages/Person";
import Search from "./pages/Search";
import Login from "./pages/Login";
import ProfileSelect from "./pages/ProfileSelect";
import { useAuth } from "./context/AuthContext";
import { useProfile } from "./context/ProfileContext";

function FullScreenSpinner() {
  return (
    <div className="min-h-screen bg-nova-bg flex items-center justify-center">
      <div className="w-8 h-8 border-2 border-nova-accent border-t-transparent rounded-full animate-spin" />
    </div>
  );
}

export default function App() {
  const { status } = useAuth();

  if (status === "loading") return <FullScreenSpinner />;
  if (status === "signedOut") return <Login />;

  return <SignedInApp />;
}

function SignedInApp() {
  const { loading, selectedProfile } = useProfile();

  if (loading) return <FullScreenSpinner />;
  if (!selectedProfile) return <ProfileSelect />;

  return (
    <Routes>
      <Route path="/" element={<Home />} />
      <Route path="/watch" element={<Watch />} />
      <Route path="/settings" element={<Settings />} />
      <Route path="/kids" element={<Kids />} />
      <Route path="/person" element={<Person />} />
      <Route path="/search" element={<Search />} />
    </Routes>
  );
}
