import { createClient } from "@supabase/supabase-js";

// Same Supabase project the Streamify Android TV app uses (see
// C:\Streamio\local.properties) - signing in here signs into the same
// account, profiles and watch history.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  console.error(
    "VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY ontbreken - zet ze in .env op de server " +
      "(zelfde waarden als in C:\\Streamio\\local.properties) en herstart de frontend-container."
  );
}

export const supabase = createClient(supabaseUrl || "", supabaseAnonKey || "");
