import test from 'node:test';
import assert from 'node:assert/strict';
import { questionTemperature } from './questionApi.ts';

test('questionTemperature omits temperature for Gemini 3.x models and keeps 0.7 for others', () => {
  for (const model of [
    'gemini-3',
    'gemini-3-flash-preview',
    'gemini-3.8-flash',
    'models/gemini-3.8-flash',
    'google/gemini-3-pro',
    'GEMINI-3.5-FLASH',
  ]) {
    assert.equal(questionTemperature(model), undefined, `expected undefined for ${model}`);
  }

  for (const model of [
    'gemini-2.5-flash',
    'gemini-flash-latest',
    'gemini-4-hydrogen',
    'models/gemini-2.5-pro',
    'gemini-30-flash',
  ]) {
    assert.equal(questionTemperature(model), 0.7, `expected 0.7 for ${model}`);
  }
});
