import { BrowserRouter, Routes, Route } from "react-router-dom";
import { VestaProvider } from "./hooks/useVesta.jsx";
import EntryPage from "./pages/EntryPage.jsx";
import TeamPage from "./pages/TeamPage.jsx";
import ParticipantPage from "./pages/ParticipantPage.jsx";

export default function App() {
  return (
    <BrowserRouter>
      <VestaProvider>
        <Routes>
          <Route path="/"            element={<EntryPage />} />
          <Route path="/team"        element={<TeamPage />} />
          <Route path="/participant" element={<ParticipantPage />} />
        </Routes>
      </VestaProvider>
    </BrowserRouter>
  );
}
