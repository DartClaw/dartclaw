package containerfixture

import "github.com/samber/lo"

var _ = lo.Sum[int]

// Total sums values.
func Total(values []int) int {
	return 0
}
