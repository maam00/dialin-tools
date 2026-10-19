import Anthropic from "@anthropic-ai/sdk";

// Created on first use, so modules can be imported (tests, --dry runs) without an API key.
let instance: Anthropic | null = null;
export const claude = (): Anthropic => (instance ??= new Anthropic());
