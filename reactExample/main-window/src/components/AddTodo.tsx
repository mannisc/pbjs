import { useState } from "react";
import { useTodo } from "../contexts/TodoContext";

export function AddTodo() {
  const [text, setText] = useState("");
  const { addTodo } = useTodo();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const response = await window.pbjs.invokeAll(
      "testSuccess",
      { test: "params" },
      { test: "data" }
    );

    if (text.trim()) {
      addTodo(text.trim() + " ✅" + JSON.stringify(response));
      setText("");
    }
  };

  return (
    <form onSubmit={handleSubmit} className="add-todo">
      <input
        type="text"
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder="Add a new todo..."
      />
      <button type="submit">Add</button>
    </form>
  );
}
