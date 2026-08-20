import { useState } from "react";
import type { ReactNode } from "react";
import { TodoContext } from "./useTodo";
import type { Todo } from "./useTodo";

// Only the provider is exported from here — see useTodo.ts for why.
export function TodoProvider({ children }: { children: ReactNode }) {
  const [todos, setTodos] = useState<Todo[]>([
    { id: 1, text: "Sample Todo", completed: false },
    { id: 2, text: "Another Todo", completed: true },
    { id: 3, text: "Third Todo", completed: false },
  ]);

  const addTodo = (text: string) => {
    setTodos([...todos, { id: Date.now(), text, completed: false }]);
  };

  const toggleTodo = (id: number) => {
    setTodos(
      todos.map((todo) =>
        todo.id === id ? { ...todo, completed: !todo.completed } : todo
      )
    );
  };

  const removeTodo = (id: number) => {
    setTodos(todos.filter((todo) => todo.id !== id));
  };

  return (
    <TodoContext.Provider value={{ todos, addTodo, toggleTodo, removeTodo }}>
      {children}
    </TodoContext.Provider>
  );
}
