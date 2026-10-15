export default {
  content: ["./index.html", "./src/**/*.{js,jsx}"],
  theme: {
    extend: {
      colors: {
        nova: {
          bg: "#080c14",
          card: "#0f1520",
          accent: "#00b4d8",
          hover: "#0096c7",
        },
      },
      keyframes: {
        "nova-fade-in": { from: { opacity: "0" }, to: { opacity: "1" } },
        "nova-kenburns": { from: { transform: "scale(1)" }, to: { transform: "scale(1.08)" } },
        "nova-logo-pulse": {
          "0%, 100%": { transform: "scale(1)" },
          "50%": { transform: "scale(1.04)" },
        },
      },
    },
  },
  plugins: [],
};
