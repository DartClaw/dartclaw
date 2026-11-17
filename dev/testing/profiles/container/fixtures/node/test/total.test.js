const assert = require('node:assert/strict');
const { test } = require('node:test');
const { total } = require('../index');

test('total sums positive and negative integers and handles empty input', () => {
  assert.equal(total([2, 3, -1]), 4);
  assert.equal(total([]), 0);
  assert.equal(total([-4, -2]), -6);
});
