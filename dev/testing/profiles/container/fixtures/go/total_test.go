package containerfixture

import "testing"

func TestTotalSumsPositiveAndNegativeIntegersAndHandlesEmptyInput(t *testing.T) {
	for _, c := range []struct {
		values []int
		want   int
	}{{[]int{2, 3, -1}, 4}, {[]int{}, 0}, {[]int{-4, -2}, -6}} {
		if got := Total(c.values); got != c.want {
			t.Errorf("Total(%v) = %d, want %d", c.values, got, c.want)
		}
	}
}
