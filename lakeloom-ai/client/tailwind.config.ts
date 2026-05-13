import type { Config } from 'tailwindcss';
import tailwindcssAnimate from 'tailwindcss-animate';

const config: Config = {
  darkMode: ['class', 'media'],
  content: [
    './index.html',
    './src/**/*.{js,ts,jsx,tsx}',
    './node_modules/@databricks/appkit-ui/**/*.{js,mjs}',
  ],
  plugins: [tailwindcssAnimate],
};

export default config;
