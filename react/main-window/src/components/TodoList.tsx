import { useTodo } from "../contexts/TodoContext";
import { TodoItem } from "./TodoItem";

export function TodoList() {
  const { todos } = useTodo();

  return (
    <div className="todo-list">
      {todos.map((todo) => (
        <TodoItem
          key={todo.id}
          id={todo.id}
          text={todo.text}
          completed={todo.completed}
        />
      ))}
    </div>
  );
}
