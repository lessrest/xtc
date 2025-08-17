// TypeScript module declarations for assets

declare module "*.wasm" {
  const wasmUrl: string;
  export default wasmUrl;
}

declare module "*.wasm?url" {
  const wasmUrl: string;
  export default wasmUrl;
}

declare module "*.wren" {
  const wrenText: string;
  export default wrenText;
}