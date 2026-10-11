<script setup lang="ts">
import type { TextPart } from '../highlight';
defineProps<{ parts: TextPart[] }>();
</script>
<template><template v-for="(part, index) in parts" :key="index"><mark v-if="part.marked">{{ part.text }}</mark><template v-else>{{ part.text }}</template></template></template>
